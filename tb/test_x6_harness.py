#!/usr/bin/env python3
"""Fast X6 harness tests: no EDA flow, no writes to the real trial ledger."""
import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from check_control_regs import inspect
from trials import throughput


class X6HarnessTests(unittest.TestCase):
    def test_count_instances_not_aliases(self):
        lines = [
            "wire \\g_m[0].g_n[0].g_ctrl_reg.ep_ctrl[0] ;\n",
            "DFFR_X1 anonymous (\n",
            "  .Q(\\g_m[0].g_n[0].g_ctrl_reg.ep_ctrl [0])\n",
            ");\n",
            "DFF_X2 ordinary (.Q(other));\n",
        ]
        total, controls = inspect(lines)
        self.assertEqual(total, 2)
        self.assertEqual(len(controls), 1)

    def test_exact_replica_gate(self):
        with tempfile.TemporaryDirectory() as tmp:
            netlist = Path(tmp) / "netlist.v"
            cells = ["DFFR_X1 anonymous (\n.Q(\\g_m[%d].g_n[%d].g_ctrl_reg.ep_ctrl [%d])\n);\n"
                     % (m, n, b) for m in range(16) for n in range(16) for b in range(3)]
            command = [sys.executable, str(ROOT / "scripts/check_control_regs.py"),
                       str(netlist), "--ctrl-reg", "1"]
            netlist.write_text("".join(cells))
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            for broken in (cells[:-1], cells + cells[:1], []):
                netlist.write_text("".join(broken))
                self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def trial_fixture(self, with_throughput=True, with_timing=True, chain=0, ii=None):
        if ii is None:
            ii = 21 - chain
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("scripts", "rtl", "experiments", "work/logs/nangate45/fp8_x6y1/base",
                         "work/results/nangate45/fp8_x6y1/base", "work/reports/nangate45/fp8_x6y1/base"):
                (root / name).mkdir(parents=True, exist_ok=True)
            for name in ("trial.sh", "nick.sh"):
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
            for name in ("amx_fp8.v", "fp8_mul.v", "fp32_add.v"):
                (root / "rtl" / name).write_text("// test-only fingerprint input\n")
            (root / "experiments/harness.md").write_text("## X6 test fixture\n")
            limiter = {"limiter_class": "reg->reg", "regreg_ws_ns": -0.7041,
                       "overall_startpoint": "ccnt[2]", "regreg_startpoint": "ccnt[2]",
                       "overall_endpoint": "lacc[5]", "regreg_endpoint": "lacc[5]"}
            if not with_timing:
                limiter = {"error": "test missing STA"}
            stub = root / "scripts/sta_limiter.sh"
            stub.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(limiter) + "'\n")
            stub.chmod(0o755)
            metrics = {
                "finish__timing__setup__ws": -0.7041,
                "finish__timing__setup__tns": -12285.5,
                "finish__timing__hold__ws": 0.0454,
                "finish__design__instance__count__stdcell": 3454124,
                "finish__design__instance__area": 4361340,
                "finish__power__total": 14.0894,
            }
            (root / "work/logs/nangate45/fp8_x6y1/base/6_report.json").write_text(json.dumps(metrics))
            (root / "work/results/nangate45/fp8_x6y1/base/6_final.v").write_text("DFF_X1 flop (\n")
            (root / "work/results/nangate45/fp8_x6y1/base/6_final.gds").write_bytes(b"test fixture")
            (root / "work/reports/nangate45/fp8_x6y1/base/5_route_drc.rpt").write_text("")
            sim = "RESULT: PASS\n"
            if with_throughput:
                sim = ("THROUGHPUT: macs_per_op=16384 initiation_interval_cycles=%d "
                       "completion_latency_cycles=20 resident_ops=4\n" % ii) + sim
            (root / "work/logs/fp8_x6y1_sim.log").write_text(sim)
            proc = subprocess.run(["bash", str(root / "scripts/trial.sh"), "-x", "6", "-y", "1",
                                   "-d", "amx_fp8", "-P", "1", "-R", "1", "--ctrl-reg", "1",
                                   "--chain", str(chain),
                                   "-p", "4.00", "--log-only", "-g", "isolated harness test"],
                                  capture_output=True, text=True,
                                  env={**os.environ, "TRIAL_GIT_ROOT": str(ROOT)})
            ledger = root / "experiments/trials.jsonl"
            self.assertTrue(ledger.exists(), proc.stdout + proc.stderr)
            return proc.returncode, json.loads(ledger.read_text())

    def test_measured_interval_is_logged_and_ranked(self):
        rc, trial = self.trial_fixture()
        self.assertEqual(rc, 0)
        self.assertEqual(trial["result"], "OK")
        self.assertNotIn("SAT", trial["knobs"])
        self.assertEqual(trial["knobs"]["CTRL_REG"], 1)
        m = trial["metrics"]
        self.assertEqual(m["initiation_interval_cycles"], 21)
        self.assertEqual(m["completion_latency_cycles"], 20)
        self.assertEqual(m["regreg_startpoint"], "ccnt[2]")
        self.assertAlmostEqual(m["mac_throughput_gmac_s"], 16384 / (21 * 4.7041))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            throughput([trial])
        self.assertIn("165.853", output.getvalue())

    def test_chaining_uses_measured_interval(self):
        rc, trial = self.trial_fixture(chain=1)
        self.assertEqual(rc, 0)
        self.assertEqual(trial["knobs"]["CHAIN"], 1)
        self.assertEqual(trial["metrics"]["initiation_interval_cycles"], 20)
        self.assertAlmostEqual(trial["metrics"]["mac_throughput_gmac_s"], 16384 / (20 * 4.7041))

    def test_wrong_schedule_is_rejected(self):
        rc, trial = self.trial_fixture(chain=1, ii=21)
        self.assertNotEqual(rc, 0)
        self.assertEqual(trial["result"], "OK_BUT_WRONG_SCHEDULE")

    def test_missing_interval_is_not_a_throughput_result(self):
        rc, trial = self.trial_fixture(with_throughput=False)
        self.assertNotEqual(rc, 0)
        self.assertEqual(trial["result"], "OK_BUT_NO_THROUGHPUT")
        self.assertNotIn("mac_throughput_gmac_s", trial["metrics"])

    def test_missing_timing_is_not_a_throughput_result(self):
        rc, trial = self.trial_fixture(with_timing=False)
        self.assertNotEqual(rc, 0)
        self.assertEqual(trial["result"], "OK_BUT_NO_THROUGHPUT")
        self.assertIsNone(trial["metrics"]["mac_throughput_gmac_s"])


if __name__ == "__main__":
    unittest.main()
