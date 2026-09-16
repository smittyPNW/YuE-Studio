import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
from studio_support import recoverable_ane_error, acquire_worker_lock, persist_state, save_render, song_directory

class FakeSong:
    def __init__(self, fail=False): self.fail=fail
    def save_artifacts(self,d):
        (d/'audio.flac').write_bytes(b'new-complete-audio')
        if self.fail: raise OSError('disk failure')
        (d/'config.json').write_text('{"steps":32}')
        return {'status':'complete','identity':'test'}

class StudioTests(unittest.TestCase):
    def test_error_classification_does_not_hide_unrelated_errors(self):
        self.assertTrue(recoverable_ane_error(RuntimeError('compile: refused')))
        self.assertTrue(recoverable_ane_error(RuntimeError('evaluate: Error Domain=com.apple.appleneuralengine Code=8')))
        for message in ('MPS out of memory','invalid input','evaluate: another error','Cancelled'):
            self.assertFalse(recoverable_ane_error(RuntimeError(message)))
    def test_failed_export_leaves_prior_master_intact(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'audio.flac').write_bytes(b'master');(p/'result.json').write_text('{"quality":"full"}')
            with self.assertRaises(OSError): save_render(FakeSong(True),p,'full',32,'mlx')
            self.assertEqual((p/'audio.flac').read_bytes(),b'master')
            self.assertEqual(json.loads((p/'result.json').read_text()),{'quality':'full'})
            self.assertFalse(list(p.glob('.render-*')))
    def test_rerender_keeps_audio_and_metadata_together(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'audio.flac').write_bytes(b'original-draft');(p/'result.json').write_text('{"quality":"draft","seed":42}')
            result=save_render(FakeSong(),p,'full',32,'mlx')
            self.assertEqual(result['ode_steps'],32)
            self.assertEqual((p/'draft.flac').read_bytes(),b'original-draft')
            self.assertEqual(json.loads((p/'draft-result.json').read_text())['seed'],42)
            version=next((p/'versions').iterdir())
            self.assertEqual((version/'audio.flac').read_bytes(),b'original-draft')
            self.assertEqual((p/'audio.flac').read_bytes(),b'new-complete-audio')
    def test_missing_audio_path_resolves_to_saved_composition(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'song1';p.mkdir()
            self.assertEqual(song_directory(p/'audio.flac'),p)
            self.assertEqual(song_directory(p),p)
    def test_exclusive_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            lock=acquire_worker_lock(Path(tmp)/'worker.lock')
            with self.assertRaises(RuntimeError): acquire_worker_lock(Path(tmp)/'worker.lock')
            lock.close()
            lock=acquire_worker_lock(Path(tmp)/'worker.lock');lock.close()
    def test_recoverable_state_is_persisted(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'song1';persist_state(p,'failed','ANE failed',engine='ane')
            state=json.loads((p/'studio-state.json').read_text())
            self.assertEqual(state['detail'],'ANE failed')
            persist_state(p,'synth','GPU retry',engine='mlx')
            self.assertEqual(json.loads((p/'studio-state.json').read_text())['engine'],'mlx')

if __name__=='__main__':unittest.main()
