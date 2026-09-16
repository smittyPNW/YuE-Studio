"""Exercise new-song admission without loading models or running synthesis."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'src'))
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('submission_worker', ROOT / 'tools/yue2_worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

class SubmissionTests(unittest.TestCase):
    def test_new_job_persists_request_and_queues_at_full_quality(self):
        request = dict(cmd='generate', title='A test song', style='Country metal',
                       lyrics='[Verse]\nAn original test line', cot='full', seed=123,
                       random_seed=False, batch=1, max_tokens=7500, engine='mlx', quality='full')
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(worker, 'OUTPUT_DIR', Path(temporary)), \
             patch.object(worker, 'PIPELINE', worker.Pipeline()), \
             patch.object(worker, 'pipeline', side_effect=AssertionError('Admission must not load models')), \
             patch.object(worker, 'emit') as emit:
            # A second submission must not overwrite the first job's metadata.
            worker.submit_generate(request)
            worker.submit_generate(dict(request, title='A second song', seed=124))
            jobs = worker.PIPELINE.jobs.snapshot()
            self.assertEqual(len(jobs), 2)
            self.assertNotEqual(jobs[0].items[0].directory, jobs[1].items[0].directory)
            for index, job in enumerate(jobs):
                item = job.items[0]
                saved = json.loads((item.directory / 'studio-job.json').read_text())
                metadata = json.loads((item.directory / 'studio.json').read_text())
                self.assertEqual(metadata['title'], ['A test song', 'A second song'][index])
                self.assertEqual(saved['lyrics'], request['lyrics'])
                self.assertEqual(saved['style'], request['style'])
                self.assertEqual(saved['seed'], 123 + index)
                self.assertEqual(item.quality, 'full')
                self.assertEqual(item.steps, 32)
                self.assertEqual(item.stage, 'queued')
                self.assertIn(item.path, worker.PIPELINE.live)
            self.assertEqual(sum(c.kwargs.get('event') == 'started' for c in emit.call_args_list), 2)
            self.assertIsNone(worker.PIPE)

if __name__ == '__main__':
    unittest.main()
