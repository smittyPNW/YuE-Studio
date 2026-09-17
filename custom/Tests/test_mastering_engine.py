import fcntl
import hashlib
import json
import math
from pathlib import Path
import signal
import struct
import subprocess
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'mastering/build/StudioMasterEngine_artefacts/Release/StudioMasterEngine'
CATALOG = json.loads((ROOT / 'custom/Assets/StudioMasteringCatalog.json').read_text())

class MasteringEngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.input = self.root / 'source.wav'
        with wave.open(str(self.input), 'wb') as w:
            w.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
            w.writeframes(b''.join(struct.pack('<hh', int(5000*math.sin(i*.071)), int(4500*math.sin(i*.043))) for i in range(48000)))
        self.original_hash = hashlib.sha256(self.input.read_bytes()).hexdigest()
        self.defaults = CATALOG['defaults'].copy()
    def tearDown(self):
        self.assertEqual(hashlib.sha256(self.input.read_bytes()).hexdigest(), self.original_hash)
        self.temp.cleanup()
    def request(self, command='analyze', **changes):
        value = dict(command=command, input=str(self.input), output=str(self.root/'master.wav'), lock=str(self.root/'work.lock'), parameters=self.defaults, presetName='Test', title='Test')
        value.update(changes)
        path=self.root/'request.json'; path.write_text(json.dumps(value)); return path
    def run_helper(self, path):
        result=subprocess.run([str(HELPER),str(path)],capture_output=True,text=True,timeout=60)
        events=[json.loads(line) for line in result.stdout.splitlines()]
        return result.returncode, events[-1]
    def test_python_generation_lock_excludes_mastering(self):
        with (self.root/'work.lock').open('w') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            code,event=self.run_helper(self.request())
            self.assertNotEqual(code,0); self.assertIn('still running',event['message'])
        code,event=self.run_helper(self.request())
        self.assertEqual(code,0); self.assertEqual(event['event'],'result')
    def test_full_renderer_preserves_format_duration_and_measures_delivery(self):
        self.defaults['useTruePeak']=False
        code,event=self.run_helper(self.request('render'))
        self.assertEqual(code,0,event)
        with wave.open(str(self.root/'master.wav'),'rb') as w:
            self.assertEqual(w.getnchannels(),2); self.assertEqual(w.getframerate(),48000); self.assertEqual(w.getnframes(),48000); self.assertEqual(w.getsampwidth(),3)
        self.assertTrue(math.isfinite(event['analysis']['lufs']))
        self.assertLess(event['analysis']['truePeak'],0)
        self.assertTrue((self.root/'master.wav.txt').exists())
        self.assertTrue((self.root/'master.json').exists())
    def test_existing_output_is_never_overwritten(self):
        target=self.root/'master.wav'; target.write_bytes(b'previous master')
        code,event=self.run_helper(self.request('render'))
        self.assertNotEqual(code,0); self.assertEqual(target.read_bytes(),b'previous master')
    def test_source_cannot_be_destination(self):
        code,event=self.run_helper(self.request('render',output=str(self.input)))
        self.assertNotEqual(code,0)
    def test_invalid_control_is_rejected(self):
        self.defaults['width']=4
        code,event=self.run_helper(self.request('render'))
        self.assertNotEqual(code,0); self.assertFalse((self.root/'master.wav').exists())
    def test_cancel_releases_lock_and_preserves_source(self):
        request=self.request('render')
        process=subprocess.Popen([str(HELPER),str(request)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        self.assertIn('Reading audio',process.stdout.readline())
        process.send_signal(signal.SIGTERM)
        stdout,stderr=process.communicate(timeout=30)
        self.assertEqual(process.returncode,130,stdout+stderr)
        self.assertFalse((self.root/'master.wav').exists())
        code,event=self.run_helper(self.request())
        self.assertEqual(code,0,event)
    def test_hifi_render_preserves_source_and_peak_headroom(self):
        self.defaults.update(bass=0.625, mud=0.12, mid=0.5, treble=0.55, punch=0.08,
                             warmExciter=0.04, airExciter=0.02, useTruePeak=True,
                             targetLufs=-14, ceilingDb=-1, normalizeActive=True, normalizeGainDb=0)
        code,event=self.run_helper(self.request('render'))
        self.assertEqual(code,0,event)
        self.assertLessEqual(event['analysis']['truePeak'],-0.9)
        self.assertTrue(math.isfinite(event['analysis']['lufs']))

    def test_max_volume_measures_full_track_and_respects_true_peak(self):
        # Quiet, transient-rich stereo material exercises gain and peak protection.
        with wave.open(str(self.input), 'wb') as w:
            w.setparams((2, 2, 48000, 0, 'NONE', 'not compressed'))
            frames=[]
            for i in range(48000 * 3):
                envelope=0.20 + (0.50 if i % 24000 < 80 else 0)
                frames.append(struct.pack('<hh', int(15000*envelope*math.sin(i*.71)), int(14500*envelope*math.sin(i*.43))))
            w.writeframes(b''.join(frames))
        self.original_hash=hashlib.sha256(self.input.read_bytes()).hexdigest()
        code,before=self.run_helper(self.request('analyze'))
        self.assertEqual(code,0,before)
        self.defaults.update(targetLufs=-9, ceilingDb=-1, useTruePeak=True,
                             normalizeActive=True, normalizeGainDb=0, masterVolDb=0, finalCharacter=0)
        code,after=self.run_helper(self.request('render'))
        self.assertEqual(code,0,after)
        self.assertGreater(after['analysis']['lufs'],before['analysis']['lufs']+1)
        self.assertLessEqual(after['analysis']['truePeak'],-0.95)
        self.assertLess(after['analysis']['samplePeak'],0)
        with wave.open(str(self.root/'master.wav'),'rb') as w:
            self.assertEqual(w.getnframes(),144000)
            self.assertEqual(w.getsampwidth(),3)
