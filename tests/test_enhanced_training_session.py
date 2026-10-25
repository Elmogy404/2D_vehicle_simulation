"""Standalone GUI launch safety and real trainer argument construction."""
from __future__ import annotations
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock, Mock, patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'enhanced_training_gui'))
from training_session import (DEFAULTS, TrainingSession, validate_settings, resume_settings,
                              model_metadata, default_godot, ENVIRONMENT_VERSION, DEFAULT_REWARD_CONFIG)


class StandaloneSessionTests(unittest.TestCase):
    def config(self, root, **overrides):
        return {**DEFAULTS, 'python_path':sys.executable, 'godot_path':sys.executable,
                'output_root':str(root/'output'), 'run_name':'test_run', **overrides}

    def test_godot_discovery_reuses_project_editor_but_prefers_environment(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            metadata = root / '.godot/editor/project_metadata.cfg'
            metadata.parent.mkdir(parents=True)
            metadata.write_text('[editor_metadata]\nexecutable_path=' + json.dumps(sys.executable))
            with patch('training_session.find_godot', side_effect=[FileNotFoundError(), sys.executable]) as find:
                self.assertEqual(default_godot(root), sys.executable)
                self.assertEqual(find.call_args.args, (sys.executable,))
            with patch('training_session.find_godot', return_value='environment-godot') as find:
                self.assertEqual(default_godot(root), 'environment-godot')
                find.assert_called_once_with()
            metadata.write_text('[editor_metadata]\nexecutable_path="C:/moved/godot.exe"')
            with patch('training_session.find_godot', side_effect=FileNotFoundError()):
                self.assertEqual(default_godot(root), '')
            metadata.write_text('broken metadata')
            with patch('training_session.find_godot', side_effect=FileNotFoundError()):
                self.assertEqual(default_godot(root), '')

    def test_missing_godot_presentation_offers_browse_and_handles_cancel(self):
        from gui_app import RunSetupTab
        view = MagicMock()
        view.params['godot_path'].get.return_value = ''
        view._default_godot.return_value = ''
        with patch('gui_app.filedialog.askopenfilename', return_value=sys.executable):
            self.assertEqual(RunSetupTab.resolve_godot(view), str(Path(sys.executable).resolve()))
            view.params['godot_path'].set.assert_called_once()
        with patch('gui_app.filedialog.askopenfilename', return_value=''):
            with self.assertRaisesRegex(FileNotFoundError, 'Run setup'):
                RunSetupTab.resolve_godot(view)

    def test_uncapped_workers_and_invalid_inputs(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            self.assertEqual(validate_settings(root,self.config(root,workers=128))['workers'],128)
            for overrides in ({'workers':0},{'workers':'abc'},{'gamma':'NaN'},
                              {'steps':'abc'},{'eval_every':0}, {'run_name':'../escape'}):
                with self.subTest(overrides=overrides),self.assertRaises(ValueError):
                    validate_settings(root,self.config(root,**overrides))

    def test_existing_run_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            models=root/'output/models'
            models.mkdir(parents=True)
            (models/'test_run.zip').write_bytes(b'keep this model')
            with self.assertRaisesRegex(ValueError,'already exists'):
                validate_settings(root,self.config(root))
            self.assertEqual((models/'test_run.zip').read_bytes(),b'keep this model')

    def test_both_modes_share_active_run_guard_and_control(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            session=TrainingSession(root)
            process=Mock(pid=os.getpid())
            process.poll.return_value=None
            with patch('training_session.subprocess.Popen',return_value=process) as spawn:
                session.start(self.config(root,workers=8),list(range(101,109)))
                second_window=TrainingSession(root)
                with self.assertRaisesRegex(ValueError,'already running'):
                    second_window.start(self.config(root))
                self.assertEqual(spawn.call_count,1)
                args=spawn.call_args.args[0]
                self.assertEqual(args[args.index('--n-envs')+1],'8')
                parents=Path(args[args.index('--visual-parents')+1])
                self.assertEqual(json.loads(parents.read_text()),list(range(101,109)))
                second_window.command('pause')
                payload=json.loads(session.control_path.read_text())
                self.assertEqual(payload['command'],'pause')
                self.assertEqual(payload['run_id'],session.read_status()['run_id'])

    def test_failed_launch_is_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            session=TrainingSession(root)
            with patch('training_session.subprocess.Popen',side_effect=OSError('injected failure')):
                with self.assertRaisesRegex(OSError,'injected'):
                    session.start(self.config(root))
            self.assertEqual(session.read_status()['state'],'failed')

    def test_each_visible_worker_needs_its_own_parent(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            session=TrainingSession(root)
            with patch('training_session.subprocess.Popen') as spawn:
                for parents in ([1],[1,1],[1,0]):
                    with self.subTest(parents=parents),self.assertRaises(ValueError):
                        session.start(self.config(root,workers=2),parents)
                spawn.assert_not_called()

    def test_resume_restores_manifest_settings_and_model_steps(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            models=root/'models'
            (models/'checkpoints').mkdir(parents=True)
            path=models/'checkpoints/test_run_8192_steps.zip'
            with zipfile.ZipFile(path,'w') as archive:
                archive.writestr('data',json.dumps({'num_timesteps':8192}))
            manifest=dict(environment_version=ENVIRONMENT_VERSION,workers=8,
                learning_rate=.0003,batch_size=64,gamma=.999,entropy_coefficient=.01,
                evaluation=dict(seed=10000,episodes=64,threshold=.9),reward_config=DEFAULT_REWARD_CONFIG)
            (models/'test_run_training_config.json').write_text(json.dumps(manifest))
            restored=resume_settings(path)
            self.assertEqual(restored['workers'],8)
            self.assertEqual(restored['run_name'],'test_run')
            self.assertEqual(Path(restored['output_root']).resolve(), root.resolve())
            self.assertEqual(model_metadata(path)['steps'],8192)
            manifest['environment_version']=2
            (models/'test_run_training_config.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError,'older environment'):
                resume_settings(path)

    def test_first_evaluation_progress_is_visible(self):
        from gui_app import HeadlessTrainingTab
        view=MagicMock()
        view.worker_tree.get_children.return_value=[]
        view.eval_tree.get_children.return_value=[]
        HeadlessTrainingTab.update_status(view,dict(state='running',phase='evaluating',
            last_evaluation={},evaluation_progress=dict(completed=8,total=64,workers=4)))
        self.assertIn('8 / 64',view.context_label.configure.call_args.kwargs['text'])


if __name__=='__main__':
    unittest.main()
