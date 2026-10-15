from pathlib import Path
import contextlib, hashlib, importlib.util, io, json, os, plistlib, shutil, subprocess

ROOT=Path(__file__).resolve().parent
(ROOT/'evidence').mkdir(exist_ok=True)
SDK=Path(os.environ.get('NRC_QT_SDK','/private/tmp/nightrider-obs-sdk'))
OBS=Path('/Applications/OBS.app/Contents/Frameworks')
BUILD=Path(os.environ.get('NRC_BUILD_DIR','/private/tmp/nightrider-panel-frames-build')).resolve(); BUILD.mkdir(parents=True,exist_ok=True)
PLUGIN=BUILD/'nightrider-panel-frames.plugin'
FIXTURE=BUILD/'Panel Frame Check.app'
for bundle in (PLUGIN,FIXTURE):
    (bundle/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    (bundle/'Contents/Resources').mkdir(exist_ok=True)

def run(args):
    subprocess.run([str(a) for a in args],check=True)

headers=[SDK/'lib'/f'{name}.framework/Headers' for name in ('QtCore','QtGui','QtWidgets')]
flags=['-std=c++17','-arch','arm64','-mmacosx-version-min=13.0','-fvisibility=hidden','-ffile-prefix-map='+str(ROOT)+'=.','-Wall','-Wextra','-Werror',
       '-F'+str(SDK/'lib'),'-I'+str(ROOT/'src'),'-I'+str(BUILD)]
flags += ['-I'+str(p) for p in headers]
links=['-framework','QtWidgets','-framework','QtGui','-framework','QtCore','-Wl,-rpath,'+str(OBS)]
run(['/usr/bin/clang++',*flags,'-bundle',ROOT/'src/plugin.cpp',ROOT/'src/panel-frames.cpp',*links,
     OBS/'obs-frontend-api.dylib',OBS/'libobs.framework/libobs','-o',PLUGIN/'Contents/MacOS/nightrider-panel-frames'])
(BUILD/'fixture-paths.hpp').write_text('#define NRC_EVIDENCE_DIR '+json.dumps(str(ROOT/'evidence'))+'\n')
run([SDK/'libexec/moc',*['-I'+str(p) for p in headers],'-F'+str(SDK/'lib'),
     ROOT/'tests/native-fixture.cpp','-o',BUILD/'native-fixture.moc'])
run([SDK/'libexec/moc',*['-I'+str(p) for p in headers],'-F'+str(SDK/'lib'),
     ROOT/'tests/PreviewProgramSizeObserver.hpp','-o',BUILD/'observer-moc.cpp'])
run(['/usr/bin/clang++',*flags,'-I'+str(ROOT/'tests'),ROOT/'tests/native-fixture.cpp',ROOT/'tests/PreviewProgramSizeObserver.cpp',BUILD/'observer-moc.cpp',ROOT/'src/panel-frames.cpp',ROOT/'src/plugin.cpp',*links,
     '-o',FIXTURE/'Contents/MacOS/panel-frame-check'])
for bundle,exe,identifier in [(PLUGIN,'nightrider-panel-frames','co.nightrider.obs.panel-frames'),
                              (FIXTURE,'panel-frame-check','co.nightrider.obs.panel-frame-check')]:
    with (bundle/'Contents/Info.plist').open('wb') as f:
        plistlib.dump({'CFBundleExecutable':exe,'CFBundleIdentifier':identifier,'CFBundleName':bundle.stem,
                      'CFBundlePackageType':'APPL' if bundle==FIXTURE else 'BNDL',
                      'CFBundleVersion':'1.1.0','CFBundleShortVersionString':'1.1.0',
                      'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True},f)
(FIXTURE/'Contents/Resources/qt.conf').write_text('[Paths]\nPrefix=/Applications/OBS.app/Contents\nPlugins=PlugIns\n')
(PLUGIN/'Contents/Resources/README.txt').write_text('NIGHTRIDERCO Panel Frames 1.1.0\nOBS Studio32.2.2 / Qt6.11.1 / arm64\n')
if (ROOT/'test-assets/theme.qss').exists():
    for name in ('theme.qss','theme-large.qss'):
        shutil.copyfile(ROOT/'test-assets'/name,FIXTURE/'Contents/Resources'/name)
else:
    spec=importlib.util.spec_from_file_location('v',ROOT.parent/'tools/verify_theme.py');v=importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):spec.loader.exec_module(v)
    for scale,padding,name in [(10,4,'theme.qss'),(14,8,'theme-large.qss')]:
        _,qss=v.compose(scale,padding)
        (FIXTURE/'Contents/Resources'/name).write_text(qss.replace('theme:',str(v.BASE.parent)+'/'))
for bundle in (PLUGIN,FIXTURE):
    # Finder metadata on generated bundles is not a signed resource.
    for path in [bundle,*bundle.rglob('*')]:
        attributes=subprocess.check_output(['/usr/bin/xattr',str(path)],text=True).splitlines()
        for attribute in ('com.apple.FinderInfo','com.apple.ResourceFork'):
            if attribute in attributes: run(['/usr/bin/xattr','-d',attribute,path])
    run(['/usr/bin/codesign','--force','--sign','-',bundle])
    run(['/usr/bin/codesign','--verify','--strict',bundle])
binary=PLUGIN/'Contents/MacOS/nightrider-panel-frames'
report={'plugin':str(PLUGIN),'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
        'sdk':'Official OBS dependencies 2026-08-26, Qt6.11.1 arm64',
        'frameworks':'Installed OBS.app Qt6.11.1; no bundled duplicate Qt runtime',
        'compiler_warnings_as_errors':True,'signing':'Local ad-hoc signature; OBS.app untouched'}
report['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in ('src','tests') for p in sorted((ROOT/folder).glob('*')) if p.is_file()}
(ROOT/'evidence/build.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
