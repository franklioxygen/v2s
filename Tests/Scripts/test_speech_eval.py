"""Scoring and gating logic of speech_eval, without building Xcode or loading models.

Run from the repository root: python3 -m unittest Tests/Scripts/test_speech_eval.py
"""
import json
from pathlib import Path
import tempfile
import unittest

from speech_eval import audio, calibrate_translation, compare_translation_strategy, history, metrics, run

EN = {'id': 'en', 'metric': 'wer'}
ZH = {'id': 'zh-Hans', 'metric': 'cer'}
CONFIG = json.loads((Path(__file__).resolve().parents[2] / 'speech_eval/config.json').read_text())


class MetricsTests(unittest.TestCase):
    def test_normalization_ignores_case_punctuation_and_spacing_only(self):
        self.assertEqual(metrics.tokens("Hey, it's the  OLD bridge!", EN), ['hey', 'it', 's', 'the', 'old', 'bridge'])
        self.assertEqual(metrics.tokens('好的。 我出门！', ZH), list('好的我出门'))
        self.assertEqual(metrics.tokens('ＡＢＣ', {'metric': 'cer'}), ['a', 'b', 'c'])

    def test_language_equivalents_apply_to_both_sides(self):
        ru = {'metric': 'wer', 'normalize': {'replace': [['ё', 'е']]}}
        self.assertEqual(metrics.tokens('Всё', ru), metrics.tokens('все', ru))
        ar = {'metric': 'wer', 'normalize': {'replace': [['أ', 'ا']], 'strip_marks': True}}
        self.assertEqual(metrics.tokens('أَرِيكَة', ar), metrics.tokens('اريكة', ar))

    def test_error_rate_counts_each_edit_kind(self):
        score, diff = metrics.score_recognition(
            ['the green sofa', 'fits the door'], [(1.0, 'the blue sofa'), (3.0, 'fits the door')], EN)
        self.assertEqual((score['substitutions'], score['deletions'], score['insertions']), (1, 0, 0))
        self.assertIn('[green]', diff)
        score, diff = metrics.score_recognition(['a b c d'], [(1.0, 'a c d x')], EN)
        self.assertEqual((score['substitutions'], score['deletions'], score['insertions']), (0, 1, 1))
        self.assertAlmostEqual(score['error_rate'], 0.5)
        self.assertIn('[+x]', diff)

    def test_lag_is_commit_time_minus_line_end_and_skips_missing_lines(self):
        score, _ = metrics.score_recognition(
            ['one two', 'three four', 'five six'], [(2.5, 'one two'), (6.0, 'three four')], EN,
            timing=[(0, 1.0), (2.0, 4.0), (5.0, 7.0)])
        self.assertEqual([line.get('lag') for line in score['per_line']], [1.5, 2.0, None])
        self.assertEqual(score['lines_missing'], 1)
        self.assertEqual(score['lag_p50'], 1.75)

    def test_perfect_and_empty_hypotheses(self):
        self.assertEqual(metrics.score_recognition(['好的'], [(1, '好的。')], ZH)[0]['error_rate'], 0)
        self.assertEqual(metrics.score_recognition(['好的'], [], ZH)[0]['accuracy'], 0)

    def test_chrf_bounds_and_ordering(self):
        reference = 'The council approved a new transport plan on Monday.'
        self.assertEqual(metrics.chrf(reference, reference), 100.0)
        self.assertEqual(metrics.chrf('', reference), 0.0)
        close = metrics.chrf('The council approved a new transit plan on Monday.', reference)
        far = metrics.chrf('Heavy rain is expected on the coast.', reference)
        self.assertGreater(close, far)
        self.assertGreater(close, 70)


class GateTests(unittest.TestCase):
    def test_recognition_gate_and_goal(self):
        targets = run.recognition_targets({'metric': 'wer'}, CONFIG)
        self.assertEqual(run.classify(0.04, targets['gate'], targets['goal']), 'goal')
        self.assertEqual(run.classify(0.08, targets['gate'], targets['goal']), 'pass')
        self.assertEqual(run.classify(0.12, targets['gate'], targets['goal']), 'fail')
        override = run.recognition_targets({'metric': 'wer', 'targets': {'recognition': {'gate': 0.15}}}, CONFIG)
        self.assertEqual(override['gate'], 0.15)

    def test_translation_settings_per_target(self):
        self.assertEqual(run.translation_settings('zh-Hans', CONFIG)['chrf_order'], 3)
        english = run.translation_settings('en', CONFIG)
        self.assertEqual(english['chrf_order'], 6)
        self.assertEqual(english['coverage_gate'], CONFIG['translation']['coverage_gate'])

    def test_translation_retention_uses_the_median_ceiling_and_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            reference = 'the market tomorrow morning'
            settings = run.translation_settings('en', CONFIG)
            rows = lambda texts: '\n'.join(json.dumps({'text': t, 'translation': t, 'ms': 5}) for t in texts) + '\n'
            ceilings = {}
            for variant, text in zip(run.CEILING_VARIANTS, [reference, reference, reference, reference, 'morning']):
                ceilings[variant] = root / f'{variant}.jsonl'
                ceilings[variant].write_text(rows([text]))
            (root / 'p.jsonl').write_text(rows(['the market tomorrow', 'morning']))
            result = run.score_translation(root / 'p.jsonl', ceilings, reference, settings)
            self.assertEqual((result['retention'], result['coverage'], result['status']), (1.0, 1.0, 'goal'))
            self.assertEqual((result['ceiling'], result['context_gain'], result['metric']), (100.0, 1.0, 'chrF6/median5'))
            # A single unusually good or bad packaging does not move the ceiling.
            ceilings['ctx2'].write_text(rows(['the market']))
            self.assertEqual(run.score_translation(root / 'p.jsonl', ceilings, reference, settings)['ceiling'], 100.0)
            (root / 'p.jsonl').write_text(rows(['the market tomorrow', '']))
            result = run.score_translation(root / 'p.jsonl', ceilings, reference, settings)
            self.assertEqual(result['status'], 'fail')
            (root / 'p.jsonl').write_text(json.dumps({'kind': 'meta', 'error': 'not installed'}) + '\n')
            self.assertEqual(run.score_translation(root / 'p.jsonl', ceilings, reference, settings)['status'], 'error')

    def test_reference_context_window_matches_app_draft_rows(self):
        items = run.translation_items_from_reference(['a.', 'b.', 'c.', 'd.'], 2)
        self.assertNotIn('context', items[0])
        self.assertEqual((items[1]['context'], items[1]['contextIndex']), (['a.', 'b.'], 1))
        self.assertEqual((items[3]['context'], items[3]['contextIndex']), (['b.', 'c.', 'd.'], 2))


class HistoryTests(unittest.TestCase):
    def record(self, run_id, rate, chrf=None):
        return {'run': run_id, 'clip': 'news', 'audio_recipe': 'x', 'mode': 'balanced', 'commit': 'abc', 'dirty': False,
                'asr': {'metric': 'wer', 'error_rate': rate, 'lines_missing': 0, 'lag_p50': 1.0, 'lag_p90': 2.0},
                'asr_status': 'pass', 'translation': {'zh-Hans': {'chrf': chrf, 'retention': 0.95}} if chrf else {},
                'translation_status': 'goal' if chrf else 'skipped'}

    def test_regressions_compare_with_the_same_audio_only(self):
        before = self.record('r1', 0.05, 60.0)
        after = self.record('r2', 0.08, 55.0)
        notes = history.regressions(after, before, CONFIG)
        self.assertEqual(len(notes), 2)
        other_audio = dict(before, audio_recipe='y')
        self.assertIsNone(history.previous([other_audio], after))
        # A chrF from a different scoring definition is not comparable.
        after['translation']['zh-Hans']['metric'] = 'chrF3/median5'
        self.assertEqual(len(history.regressions(after, before, CONFIG)), 1)

    def test_replace_run_keeps_other_runs_and_order(self):
        with tempfile.TemporaryDirectory() as directory:
            lang_dir = Path(directory)
            for run_id in ('r1', 'r2', 'r3'):
                history.append(lang_dir, self.record(run_id, 0.05, 60.0))
            history.replace_run(lang_dir, 'r2', [self.record('r2', 0.05, 70.0)])
            records = history.load(lang_dir)
            self.assertEqual([r['run'] for r in records], ['r1', 'r2', 'r3'])
            self.assertEqual([r['translation']['zh-Hans']['chrf'] for r in records], [60.0, 70.0, 60.0])

    def test_history_files_are_written_per_language(self):
        with tempfile.TemporaryDirectory() as directory:
            lang_dir = Path(directory) / 'en'
            lang_dir.mkdir()
            lang = {'id': 'en', 'name': 'English', 'metric': 'wer', 'expected_backend': 'on-device',
                    'translation_targets': ['zh-Hans']}
            history.append(lang_dir, self.record('r1', 0.05, 60.0))
            history.append(lang_dir, self.record('r2', 0.04, 61.0))
            history.render(lang_dir, lang, CONFIG, run.recognition_targets(lang, CONFIG))
            text = (lang_dir / 'HISTORY.md').read_text()
            self.assertIn('| r2 |', text)
            self.assertIn('-1.0', text)
            history.render_summary(Path(directory), [(lang_dir, lang)])
            self.assertIn('English', (Path(directory) / 'SUMMARY.md').read_text())


class ScriptTests(unittest.TestCase):
    def test_all_languages_have_parallel_scripts_and_config(self):
        languages = run.load_languages(None)
        self.assertGreaterEqual(len(languages), 27)
        counts = {clip: len(audio.parse_script(run.LANGUAGES / 'en' / f'{clip}.txt')) for clip in run.CLIPS}
        for lang_dir, lang in languages:
            for clip in run.CLIPS:
                lines = audio.parse_script(lang_dir / f'{clip}.txt')
                self.assertEqual(len(lines), counts[clip], f'{lang["id"]}/{clip}')
                if clip == 'dialogue':
                    self.assertEqual([s for s, _ in lines], ['A', 'B'] * (counts[clip] // 2), lang['id'])
                self.assertFalse(any(ch.isdigit() for _, text in lines for ch in text), f'{lang["id"]}/{clip} has digits')
            for target in lang['translation_targets']:
                self.assertTrue((run.LANGUAGES / target / 'news.txt').exists(), target)
            self.assertIn(lang['metric'], ('wer', 'cer'))


class CalibrationTests(unittest.TestCase):
    LINES = ['Hello there, friend. How are you?', 'Fine, thanks.', 'See you soon.']

    def test_noise_variants_keep_every_word(self):
        lang = {'metric': 'wer'}
        def words(items):
            return metrics.tokens(' '.join(i['text'] for i in items), lang)
        expected = words([{'text': line} for line in self.LINES])
        for variant in calibrate_translation.NOISE:
            self.assertEqual(words(calibrate_translation.noise_items(variant, self.LINES, lang)), expected, variant)
        split = [i['text'] for i in calibrate_translation.noise_items('split', self.LINES, lang)]
        self.assertEqual(split[:2], ['Hello there, friend.', 'How are you?'])
        self.assertEqual(len(calibrate_translation.noise_items('merge', self.LINES, lang)), 2)
        cjk = calibrate_translation.noise_items('split', ['好的。我们走吧！'], {'metric': 'cer'})
        self.assertEqual([i['text'] for i in cjk], ['好的。', '我们走吧！'])
        self.assertEqual(run.packaging_items('ctx2', self.LINES, lang, 2),
                         run.translation_items_from_reference(self.LINES, 2))

    def test_simulated_errors_hit_the_requested_rate_and_keep_punctuation(self):
        lang = {'metric': 'wer'}
        lines = run.reference_lines(run.LANGUAGES / 'en', 'news')
        damaged = calibrate_translation.corrupt(lines, 0.10, False, 'seed')
        self.assertEqual(damaged, calibrate_translation.corrupt(lines, 0.10, False, 'seed'))
        score, _ = metrics.score_recognition(lines, [(0.0, text) for text in damaged], lang)
        self.assertGreater(score['error_rate'], 0.05)
        self.assertLess(score['error_rate'], 0.16)
        self.assertEqual([line[-1] for line in damaged], [line[-1] for line in lines])
        items = calibrate_translation.damaged_items('dup3', lines, lang, 'seed', 2)
        self.assertEqual(len(items), len(lines) + 3)
        self.assertEqual(len(calibrate_translation.damaged_items('drop2', lines, lang, 'seed', 2)), len(lines) - 2)


if __name__ == '__main__':
    unittest.main()


class StrategyComparisonTests(unittest.TestCase):
    def test_strategy_order_alternates_between_pairs(self):
        self.assertEqual(compare_translation_strategy.job_order(['default', 'lowLatency'], 0), ['default', 'lowLatency'])
        self.assertEqual(compare_translation_strategy.job_order(['default', 'lowLatency'], 1), ['lowLatency', 'default'])

    def test_summary_separates_cold_start_and_compares_with_the_baseline(self):
        def rows(translations, ms, strategy):
            return [{'translation': t, 'ms': m, 'strategy': strategy} for t, m in zip(translations, ms)]

        score = compare_translation_strategy.score_group
        reference = 'the old bridge has the nicest flowers'
        groups = [
            {'pair': 'de.news.en', 'first': 'default', 'scores': {
                'default': score(rows(['the old bridge', 'has the nicest flowers'], [900, 100], 'highFidelity'), reference, 6),
                'lowLatency': score(rows(['the old bridge', 'has the nicest flowers'], [500, 40], 'lowLatency'), reference, 6),
            }},
            {'pair': 'fr.news.en', 'first': 'lowLatency', 'scores': {
                'default': score(rows(['the old bridge', 'has the nicest flowers'], [800, 120], 'highFidelity'), reference, 6),
                'lowLatency': score(rows(['a bridge', 'flowers'], [400, 60], 'lowLatency'), reference, 6),
            }},
        ]
        summary = compare_translation_strategy.summarize(groups, ['default', 'lowLatency'], 2.0)
        self.assertEqual(summary['resolved'], {'default': ['highFidelity'], 'lowLatency': ['lowLatency']})
        low = summary['strategies']['lowLatency']
        self.assertEqual((low['warm_ms_p50_run_first'], low['warm_ms_p50_run_second']), (60, 40))
        self.assertEqual(low['cold_ms_p50'], 400)
        self.assertEqual(summary['strategies']['default']['warm_ms_p90'], 120)
        versus = low['vs_default']
        self.assertEqual((versus['identical_pairs'], versus['worse_pairs'], versus['better_pairs']), (1, 1, 0))
        self.assertLess(versus['chrf_delta_min'], -2.0)

    def test_pairs_a_strategy_cannot_translate_are_left_out_of_the_comparison(self):
        reference = 'the old bridge'
        good = [{'translation': 'the old bridge', 'ms': m, 'strategy': 'highFidelity'} for m in (900, 100)]
        failed = [{'translation': '', 'ms': 5, 'strategy': 'lowLatency',
                   'error': 'TranslationError(cause: Translation.TranslationError.Cause.notInstalled, sourceLanguage: nil)'}]
        score = compare_translation_strategy.score_group
        groups = [{'pair': 'da.news.en', 'first': 'default',
                   'scores': {'default': score(good, reference, 6), 'lowLatency': score(failed * 2, reference, 6)}}]
        summary = compare_translation_strategy.summarize(groups, ['default', 'lowLatency'], 2.0)
        self.assertEqual(summary['pairs'], 0)
        self.assertEqual(summary['unavailable']['lowLatency'], {'notInstalled': ['da.news.en']})
        self.assertIsNone(summary['strategies']['lowLatency']['vs_default']['chrf_delta_median'])
