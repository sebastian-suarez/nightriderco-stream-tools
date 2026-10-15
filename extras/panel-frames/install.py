from pathlib import Path
import datetime, hashlib, json, os, platform, plistlib, shutil, stat, subprocess, tempfile, uuid, zipfile

root=Path(__file__).resolve().parent
def require(condition, message):
    if not condition:
        raise SystemExit(message)

manifest=json.loads((root/'manifest.json').read_text())
archive=root/'nightrider-panel-frames.plugin.zip'
require(hashlib.sha256(archive.read_bytes()).hexdigest()==manifest['archive_sha256'], 'Extension archive checksum mismatch')
require(platform.machine()=='arm64', 'This build is for Apple silicon Macs')
obs=Path('/Applications/OBS.app/Contents')
with (obs/'Info.plist').open('rb') as f:
    obsVersion=plistlib.load(f)['CFBundleShortVersionString']
require(obsVersion=='32.2.2', 'This build was verified with OBS 32.2.2')
with (obs/'Frameworks/QtCore.framework/Resources/Info.plist').open('rb') as f:
    qt=plistlib.load(f)['CFBundleVersion']
require(qt=='6.11.1', 'This build was verified with the Qt 6.11.1 runtime in OBS 32.2.2')
verification=json.loads((root/'verification.json').read_text())
require(verification['passed'] and verification['native_surface_destructions']==0, 'Native lifecycle verification is required')
require(verification['binary_sha256']==manifest['binary_sha256'], 'Verification must identify this extension binary')
destination=Path.home()/'Library/Application Support/obs-studio/plugins'
destination.mkdir(parents=True,exist_ok=True)
installed=destination/'nightrider-panel-frames.plugin'
backup=None
with tempfile.TemporaryDirectory(prefix='.nrc-panel-frames-',dir=destination) as temporary:
    staging=Path(temporary).resolve()
    with zipfile.ZipFile(archive) as z:
        for entry in z.infolist():
            path=(staging/entry.filename).resolve()
            require(path.is_relative_to(staging) and not stat.S_ISLNK(entry.external_attr>>16), 'Unsafe archive entry')
        z.extractall(staging)
    bundle=staging/'nightrider-panel-frames.plugin'
    binary=bundle/'Contents/MacOS/nightrider-panel-frames'
    binary.chmod(0o755)
    require(hashlib.sha256(binary.read_bytes()).hexdigest()==manifest['binary_sha256'], 'Extension binary checksum mismatch')
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(bundle)],check=True)
    if installed.exists():
        backupRoot=Path.home()/'Library/Application Support/NIGHTRIDERCO/StyleBackups'
        backupRoot.mkdir(parents=True,exist_ok=True)
        backup=backupRoot/(datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S')+'-panel-frames-'+uuid.uuid4().hex[:6])
        backup.mkdir()
        shutil.copytree(installed,backup/installed.name)
        # Replacement is only attempted after a complete validated backup exists.
        old=staging/'previous.plugin'
        os.replace(installed,old)
        try: os.replace(bundle,installed)
        except Exception:
            os.replace(old,installed)
            raise
    else: os.replace(bundle,installed)
result={'installed':str(installed),'binary_sha256':manifest['binary_sha256'],'backup':str(backup) if backup else None,
        'status':'installed_pending_next_obs_launch','running_obs_restarted':False}
print(json.dumps(result,indent=2))
