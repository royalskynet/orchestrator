#!/usr/bin/env python3
"""離線檢查 freepool 通知標題與摘要不重複；--mutate 在暫存副本還原舊錯誤。"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parents[1] / 'bin/oc-probe'
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    script = root / 'oc-probe/bin/oc-probe'
    script.parent.mkdir(parents=True)
    shutil.copy(source, script)
    if '--mutate' in sys.argv:
        text = script.read_text()
        assert '"免費模型池價格警示"' in text
        script.write_text(text.replace('"免費模型池價格警示"', '"${msg%%$\'\\n\'*}"'))
    home = root / 'home'
    notify = home / '.hermes/profiles/coco/scripts/brief/notify'
    notify.parent.mkdir(parents=True)
    shutil.copy(Path.home() / '.hermes/profiles/coco/scripts/brief/notify', notify)
    for name, content in {
        'bin/freepool-guard': '#!/bin/bash\necho "guard detail"\nexit 1\n',
        'oc-probe/bin/go-sync': '#!/bin/bash\nexit 0\n',
        'bin/dcq': '#!/bin/bash\nexit 0\n',
    }.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)
    queue = root / 'queue'
    env = dict(os.environ, HOME=str(home), DCQ_BIN=str(root / 'bin/dcq'), COCO_DIGEST_DIR=str(queue))
    result = subprocess.run(['bash', str(script), 'daily'], env=env, capture_output=True, text=True)
    assert result.returncode == 1, result
    records = list(queue.glob('*.json'))
    assert len(records) == 1, records
    item = json.loads(records[0].read_text())
    assert 'guard detail' in item['body'], item
    spec = importlib.util.spec_from_file_location('morning_digest', Path.home() / 'OpenBot/Shared/fleet/morning_digest.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rendered = module.render([(None, item)], '11-07')
    phrase = '清冊有 billing=free 的模型在上游已不是零價'
    assert rendered.count(phrase) == 1, rendered
    assert rendered.count('freepool') == 1, rendered
    print(rendered)
    print('PASS freepool_notify_test')
