"""Inspect a mounted local DMG candidate and smoke-test its bundled tools.

Usage: python3 tests/bundle_smoke.py [--release] /absolute/path/to/candidate.dmg
Requires a candidate built with DUMPTRUCK_CAMERA_HELPERS=1.
--release also requires a Developer ID signature, the hardened runtime on our
executables, a stapled notarization ticket, and Gatekeeper acceptance.
"""
from pathlib import Path
import hashlib,json,os,subprocess,tempfile,sys
root=Path(__file__).resolve().parent.parent
args=sys.argv[1:];release='--release' in args;args=[a for a in args if a!='--release']
if len(args) != 1:
    raise SystemExit("Usage: python3 tests/bundle_smoke.py [--release] /path/to/candidate.dmg")
dmg=Path(args[0]).resolve()
def signature(path):
 return subprocess.run(['codesign','-dvvv',str(path)],capture_output=True,text=True).stderr
if release:
 subprocess.run(['xcrun','stapler','validate',str(dmg)],check=True,stdout=subprocess.DEVNULL)
 subprocess.run(['spctl','--assess','--type','open','--context','context:primary-signature',str(dmg)],check=True)
(root/".tmp_codex").mkdir(exist_ok=True)
mount=Path(tempfile.mkdtemp(prefix='candidate-mount-',dir=root/'.tmp_codex'))
work=Path(tempfile.mkdtemp(prefix='candidate-check-',dir=root/'.tmp_codex'))
subprocess.run(['hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),str(dmg)],check=True,stdout=subprocess.DEVNULL)
try:
 app=mount/'Dumptruck.app';engine=app/'Contents/Resources/engine';bin=engine/'.venv/bin';legal=app/'Contents/Resources/legal'
 subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
 if release:
  subprocess.run(['spctl','--assess','--type','execute',str(app)],check=True)
  ours=[app,engine/'python/bin/python3.13',bin/'ffmpeg',bin/'ffprobe']+[p for p in (engine/'tools').glob('*-probe')]
  for path in ours:
   info=signature(path)
   assert 'Authority=Developer ID Application:' in info,(path,'not Developer ID signed')
   assert 'runtime' in info.split('flags=')[1].split()[0],(path,'no hardened runtime')
   assert 'Timestamp=' in info,(path,'no secure timestamp')
  print('Developer ID, hardened runtime, timestamps, stapled ticket and Gatekeeper checks passed.')
 records=json.loads((legal/'cameras/CAMERA_RUNTIME_SHA256.json').read_text())
 # Ad-hoc vendor files are re-signed with ours for notarization; every other vendor byte must match.
 resigned={'tools/vendor/arri/arriimagesdk_plugins/libjpegxs-lib.dylib'}
 for name,want in records.items():
  if name in resigned:subprocess.run(['codesign','--verify','--strict',str(engine/name)],check=True);continue
  assert hashlib.sha256((engine/name).read_bytes()).hexdigest()==want,name
 assert 'Apache License' in (legal/'LICENSE').read_text()
 assert len(list((app/'Contents/Resources/sfx').rglob('*.mp3')))==9
 assert (app/'Contents/Resources/AppIcon.icns').is_file()
 assert (engine/'legal/ffmpeg/ffmpeg-9.0.1.tar.xz').is_file()
 assert (engine/'legal/python/LICENSE.zlib-ng.txt').is_file()
 forbidden={'.h','.hpp','.cpp','.a'}
 assert not any(p.suffix in forbidden for p in (engine/'tools').rglob('*'))
 ff=bin/'ffmpeg';probe=bin/'ffprobe';movie=work/'sample.mov';thumb=work/'sample.jpg'
 subprocess.run([str(ff),'-v','error','-f','lavfi','-i','color=c=orange:s=320x240:r=24','-t','0.5','-c:v','mpeg4',str(movie)],check=True)
 info=json.loads(subprocess.check_output([str(probe),'-v','quiet','-print_format','json','-show_streams',str(movie)]))
 assert info['streams'][0]['width']==320
 subprocess.run([str(ff),'-v','error','-i',str(movie),'-frames:v','1',str(thumb)],check=True)
 assert thumb.stat().st_size>0
 # PNG video and OpenEXR need zlib, which --disable-autodetect can silently drop.
 for codec,suffix in [('png','mov'),('prores_ks','mov'),('exr','exr')]:
  sample=work/(codec+'.'+suffix);preview=work/(codec+'-preview.jpg')
  subprocess.run([str(ff),'-v','error','-f','lavfi','-i','color=c=orange:s=320x240:r=24','-frames:v','1','-c:v',codec,str(sample)],check=True)
  subprocess.run([str(ff),'-v','error','-i',str(sample),'-frames:v','1',str(preview)],check=True)
  assert preview.stat().st_size>0,codec
 assert 'videotoolbox' in subprocess.check_output([str(ff),'-hide_banner','-hwaccels'],text=True)
 env=dict(os.environ,PATH=str(bin)+':/usr/bin:/bin:/usr/sbin:/sbin',PYTHONDONTWRITEBYTECODE='1')
 reported=subprocess.check_output([str(bin/'python'),'-m','dumptruck.cli','--version'],cwd=engine,env=env,text=True).split()[1]
 plist=subprocess.check_output(['defaults','read',str(app/'Contents/Info.plist'),'CFBundleShortVersionString'],text=True).strip()
 assert plist==reported,('Info.plist version',plist,'engine version',reported)
 # A real input is unavailable locally; exercise SDK initialization with deliberate corrupt data.
 bad=work/'invalid.r3d';bad.write_bytes(b'not a camera clip\n'*256)
 for name,expected in [('r3d-probe',6),('braw-probe',5)]:
  result=subprocess.run([str(engine/'tools'/name),str(bad),str(work/(name+'.jpg'))],capture_output=True,text=True,env=env)
  assert result.returncode==expected,(name,result.returncode,result.stderr)
  print(name,'initialized and rejected corrupt input without crashing')
 print('Mounted DMG passed signatures, vendor hashes, artwork/sounds, offline notices, bundled Python, FFmpeg metadata and JPEG checks.')
 print('No real RED/ARRI/BRAW clip decode was tested in this run.')
finally:
 subprocess.run(['hdiutil','detach',str(mount)],check=True,stdout=subprocess.DEVNULL)
 mount.rmdir()
