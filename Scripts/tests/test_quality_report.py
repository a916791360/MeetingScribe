#!/usr/bin/env python3
"""指标脚本自己的单测：钉住「不可算」语义与判据一致性。

为什么要有这一层：`--check` 用的是**合成语料**，验的是「给定这份 run，判定是否如预期」。
但合成语料永远是「字段齐全」或「整块缺失」的整齐形态，而真正会把人带沟里的是
**代码内部的判据**——比如有人把「字段不存在」的 `None` 改成 `0`，或者把空话检测
从句式匹配退回裸词匹配。那些改动手边没有反向样本就看不出来，所以在这里补。

跑法（无需任何依赖、无需网络，纯标准库）：
    python3 Scripts/tests/test_quality_report.py
"""

from __future__ import annotations

import importlib.util
import contextlib
import io
import pathlib
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parent.parent.parent
QR_PATH = REPO / "Scripts/quality_report.py"

spec = importlib.util.spec_from_file_location("quality_report", QR_PATH)
qr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qr)


def a_case(case_id="t", expect="content", duration=2700.0, n_seg=10, char_count=None):
    segs = [{"start": float(i), "end": float(i + 1), "text": "这是一句测试用的话。",
             "confidence": 0.9} for i in range(n_seg)]
    chars = char_count if char_count is not None else sum(len(s["text"]) for s in segs)
    return {"caseId": case_id, "label": case_id, "expect": expect,
            "durationSeconds": duration, "segmentCount": n_seg, "charCount": chars,
            "segments": segs}


def a_run(**over):
    r = {
        "ok": True, "errorType": None, "elapsedSeconds": 10.0,
        "preparedSegmentCount": 5, "preparedCharCount": 90, "dedupCharCount": 92,
        "finishReason": "stop", "minutesFinishReason": "stop",
        "analysis": {"headline": "结论", "overviewText": "速览正文" * 40,
                     "minutesText": "## 一、小节\n\n" + "纪要正文" * 300,
                     "overviewBullets": ["[00:10] 有数字 3 的要点"],
                     "decisions": [{"label": "d"}] * 12,
                     "actions": [{"label": "a", "owner": "甲"}] * 4 + [{"label": "a"}] * 8,
                     "openQuestions": ["q"]},
    }
    r.update(over)
    return r


class MissingFieldNeverBecomesZero(unittest.TestCase):
    """字段不在 → 「不可算」（None），绝不许拿 0 冒充。

    这个坑阶段 0 已经栽过一次：`overviewBullets` 还没做的时候，
    「功能没做」被读成「做了但效果差」，差点去改一个没坏的东西。
    """

    def test_actions_without_owner_key_report_none(self):
        run = a_run()
        run["analysis"]["actions"] = [{"label": "a"}] * 12  # 完全没有 owner 键
        m = qr.metrics_for(a_case(), run)
        self.assertIsNone(m["actionsWithOwner"])
        self.assertIsNone(m["actionsWithOwnerRatio"])

    def test_actions_with_owner_key_present_but_empty_string_is_zero(self):
        """键在、值全是空串 → 这才是真的 0%，要如实报 0 而不是不可算。"""
        run = a_run()
        run["analysis"]["actions"] = [{"label": "a", "owner": ""}] * 12
        m = qr.metrics_for(a_case(), run)
        self.assertEqual(m["actionsWithOwner"], 0)
        self.assertEqual(m["actionsWithOwnerRatio"], 0.0)

    def test_missing_overview_bullets_reports_none(self):
        run = a_run()
        del run["analysis"]["overviewBullets"]
        m = qr.metrics_for(a_case(), run)
        self.assertIsNone(m["overviewBulletCount"])
        self.assertIsNone(m["overviewBulletsWithFacts"])

    def test_failed_run_reports_none_not_zero(self):
        m = qr.metrics_for(a_case(), {"ok": False, "errorType": "networkFailed"})
        self.assertEqual(m["status"], "failed")
        for key in ("minutesChars", "emptyPhraseCount", "actionsWithOwnerRatio"):
            self.assertIsNone(m[key], f"{key} 在失败场次里必须是不可算")


class AbsoluteCountsOnlyJudgedOnLongEnoughCases(unittest.TestCase):
    """决策/待办 ≥12/≥10 是**绝对条数**，只对够长的会成立。"""

    def test_short_case_reports_none(self):
        m = qr.metrics_for(a_case(duration=900.0), a_run())
        self.assertIsNone(m["decisionCountJudged"])
        self.assertIsNone(m["actionCountJudged"])
        self.assertIsNotNone(m["decisionPerHour"], "密度型指标照旧要有值")

    def test_long_case_judged(self):
        m = qr.metrics_for(a_case(duration=2700.0), a_run())
        self.assertEqual(m["decisionCountJudged"], 12)


class SegmentRatioOnlyJudgedOnPathologicalDensity(unittest.TestCase):
    """句子级转录没有可折叠的东西 —— 比值接近 1 不是「后处理没生效」。"""

    def test_normal_density_not_judged(self):
        m = qr.metrics_for(a_case(n_seg=100, duration=600.0), a_run())
        self.assertIsNone(m["segmentRatioJudged"])

    def test_pathological_density_judged(self):
        m = qr.metrics_for(a_case(n_seg=220, duration=600.0), a_run())
        self.assertIsNotNone(m["segmentRatioJudged"])


class EmptyPhraseRuleUsesSentencePatternNotBareWords(unittest.TestCase):
    """空话检测必须按句式，不能裸词 —— 否则会把实质内容误伤（实测栽过）。"""

    def test_real_content_containing_weirao_zhankai_is_not_empty_talk(self):
        text = "后续给用户表现的形态也要围绕问答、视频和远程协助展开"
        self.assertEqual(qr.count_empty_phrases(text), 0)

    def test_opening_cliche_is_empty_talk(self):
        self.assertGreater(qr.count_empty_phrases("本次会议围绕会员体系改版展开。"), 0)

    def test_plain_cliche_verbs_are_empty_talk(self):
        self.assertGreater(qr.count_empty_phrases("会上介绍了三个方案，会上讨论了排期。"), 0)

    def test_meta_comment_is_detected(self):
        self.assertGreater(qr.count_phrases("本次输入材料中不包含任何内容", qr.META_PHRASES), 0)


class OneVerdictSourceForUiAndReport(unittest.TestCase):
    """「达标/未达」只能有一个来源：阈值表。加了新阈值不许再在别处写数字。"""

    def test_verdict_of_agrees_with_thresholds(self):
        for key, _desc, kind, target in qr.thresholds():
            if kind == "ge":
                self.assertEqual(qr.verdict_of(key, target), "达标", key)
                self.assertEqual(qr.verdict_of(key, target - 1e-9), "未达", key)
            elif kind == "le":
                self.assertEqual(qr.verdict_of(key, target), "达标", key)
                self.assertEqual(qr.verdict_of(key, target + 1e-9), "未达", key)
            elif kind == "range":
                lo, hi = target
                self.assertEqual(qr.verdict_of(key, lo), "达标", key)
                self.assertEqual(qr.verdict_of(key, hi), "达标", key)
                self.assertEqual(qr.verdict_of(key, lo - 1), "未达", key)
                self.assertEqual(qr.verdict_of(key, hi + 1), "未达", key)

    def test_none_is_always_incalculable(self):
        for key, *_ in qr.thresholds():
            self.assertEqual(qr.verdict_of(key, None), "不可算", key)

    def test_unknown_key_raises(self):
        with self.assertRaises(KeyError):
            qr.verdict_of("noSuchMetric", 1)


class EmptyStateVerdictIsSingleFunction(unittest.TestCase):
    def test_clean_empty_state(self):
        self.assertEqual(qr.empty_state_verdict({"metaCommentCount": 0, "overviewChars": 0,
                                                 "minutesChars": 0}), "达标（干净空态）")

    def test_meta_comment_fails(self):
        self.assertEqual(qr.empty_state_verdict({"metaCommentCount": 3, "overviewChars": 100,
                                                 "minutesChars": 200}), "未达（产出了元评论）")

    def test_content_without_meta_keywords_is_flagged_for_human(self):
        self.assertIn("存疑", qr.empty_state_verdict(
            {"metaCommentCount": 0, "overviewChars": 100, "minutesChars": 200}))


class SyntheticCorpusCheckPasses(unittest.TestCase):
    """合成语料自测必须绿 —— 它是 CI 的第一道门。"""

    def test_check_exits_zero(self):
        proc = subprocess.run(
            [sys.executable, str(QR_PATH), "--corpus",
             str(REPO / "docs/verification/quality/synthetic"), "--check"],
            capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("全部一致", proc.stdout)


class GateItselfBites(unittest.TestCase):
    """反向证伪：把**历史上真的犯过**的退化塞回代码里，门禁必须变红。

    只断言「门禁现在是绿的」是不够的 —— 一个永远返回 0 的检查也是绿的。
    所以这里逐个把退化打进去，要求灯真的亮；哪一个打进去还是绿的，
    就说明合成语料缺了对应的探针，fixture 要补，而不是把这条测试删掉。
    """

    SAVED = ("EMPTY_PHRASES", "EMPTY_PATTERNS", "thresholds",
             "metrics_for", "empty_state_verdict")

    def setUp(self):
        qr.configure_root(REPO / "docs/verification/quality/synthetic")
        self._saved = {n: getattr(qr, n) for n in self.SAVED}

    def tearDown(self):
        for n, v in self._saved.items():
            setattr(qr, n, v)

    def _rows(self):
        rows = []
        for cp in sorted(qr.CASES.glob("*.json")):
            case = qr.load_json(cp)
            rows.append(qr.metrics_for(case, qr.load_json(qr.RUNS / f"{case['caseId']}.json")))
        return rows

    def _gate_is_red(self) -> bool:
        with contextlib.redirect_stdout(io.StringIO()):
            return qr.run_check(self._rows()) != 0

    def test_baseline_is_green(self):
        self.assertFalse(self._gate_is_red(), "基线没退化时门禁必须是绿的")

    # ---- 退化 1：空话检测的两套机制各失效一次（口径历史见 quality_report.py 注释）
    def test_bare_word_matching_of_weirao_is_caught(self):
        qr.EMPTY_PHRASES = qr.EMPTY_PHRASES + ["围绕"]
        self.assertTrue(self._gate_is_red(), "「围绕」被当裸词仍应被抓到")

    def test_sentence_pattern_losing_anchors_is_caught(self):
        qr.EMPTY_PATTERNS = [qr.re.compile(r"围绕[^。；\n]{0,40}展开")]
        self.assertTrue(self._gate_is_red(), "句式表丢了句首边界必须被抓到")

    def test_sentence_pattern_going_silent_is_caught(self):
        qr.EMPTY_PATTERNS = [qr.re.compile(r"(?!x)x")]
        self.assertTrue(self._gate_is_red(), "句式表整个失效必须被抓到")

    def test_bare_word_list_going_silent_is_caught(self):
        qr.EMPTY_PHRASES = []
        self.assertTrue(self._gate_is_red(), "裸词表被清空必须被抓到")

    # ---- 退化 2：阈值被悄悄放松
    def test_relaxed_threshold_is_caught(self):
        orig = qr.thresholds
        qr.thresholds = lambda: [
            (k, d, kind, (9999 if k == "minutesChars" else t))
            for k, d, kind, t in orig()
        ]
        self.assertTrue(self._gate_is_red(), "minutesChars 阈值被改必须被抓到")

    # ---- 退化 3：缺字段拿 0 冒充（「不可算」被压成「未达」）
    def test_missing_field_faked_as_zero_is_caught(self):
        orig = qr.metrics_for

        def bad(case, run):
            m = orig(case, run)
            for k in ("actionsWithOwnerRatio", "overviewBulletsWithFacts"):
                if m.get(k) is None:
                    m[k] = 0
            return m

        qr.metrics_for = bad
        self.assertTrue(self._gate_is_red(), "缺字段用 0 冒充必须被抓到")

    # ---- 退化 4：空态判定写死「干净」，不再看元评论
    def test_hardcoded_empty_state_verdict_is_caught(self):
        qr.empty_state_verdict = lambda row: "达标（干净空态）"
        self.assertTrue(self._gate_is_red(), "空态判定不看元评论必须被抓到")

    # ---- 退化 5：段数回退不再可见（PREPARED 段数不再参与判定）
    def test_segment_regression_going_unseen_is_caught(self):
        orig = qr.metrics_for

        def bad(case, run):
            m = orig(case, run)
            m["segmentRatioJudged"] = 1.0
            return m

        qr.metrics_for = bad
        self.assertTrue(self._gate_is_red(), "段数回退被抹平必须被抓到")


if __name__ == "__main__":
    unittest.main()
