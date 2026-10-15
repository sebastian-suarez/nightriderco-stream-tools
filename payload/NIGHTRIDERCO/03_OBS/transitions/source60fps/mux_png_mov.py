"""Mux RGBA PNG frames into a standard QuickTime video, preserving alpha."""
from pathlib import Path
import json
import struct
import zlib

def u16(*values): return struct.pack(">"+"H"*len(values), *values)
def u32(*values): return struct.pack(">"+"I"*len(values), *values)
def atom(kind, payload=b""): return u32(8+len(payload))+kind.encode("ascii")+payload
def full(kind, payload=b"", flags=0): return atom(kind,u32(flags)+payload)
matrix=u32(0x10000,0,0,0,0x10000,0,0,0,0x40000000)
width,height,fps=2560,1440,60
frames=[p.read_bytes() for p in sorted(Path("work/native_motion60/frames").glob("frame-*.png"))]
assert len(frames)==72
ftyp=atom("ftyp",b"qt  "+u32(0)+b"qt  ")
mdat=atom("mdat",b"".join(frames))
chunk_offset=len(ftyp)+8
duration=len(frames)
mvhd=full("mvhd",u32(0,0,fps,duration,0x10000)+u16(0x100)+b"\0"*10+matrix+b"\0"*24+u32(2))
tkhd=full("tkhd",u32(0,0,1,0,duration)+b"\0"*8+u16(0,0,0,0)+matrix+u32(width<<16,height<<16),flags=7)
mdhd=full("mdhd",u32(0,0,fps,duration)+u16(0,0))
hdlr=full("hdlr",b"mhlr"+b"vide"+b"\0"*12+b"NIGHTRIDERCO PNG alpha video\0")
vmhd=full("vmhd",u16(0,0,0,0),flags=1)
dref=full("dref",u32(1)+full("url ",flags=1))
dinf=atom("dinf",dref)
compressor=b"PNG with alpha"
compressor_name=bytes([len(compressor)])+compressor+b"\0"*(31-len(compressor))
sample_entry=atom("png ",b"\0"*6+u16(1,0,0)+b"appl"+u32(0,0x400)+u16(width,height)+u32(72<<16,72<<16,0)+u16(1)+compressor_name+u16(32,0xffff))
stsd=full("stsd",u32(1)+sample_entry)
stts=full("stts",u32(1,duration,1))
stsc=full("stsc",u32(1,1,duration,1))
stsz=full("stsz",u32(0,duration)+u32(*(len(frame) for frame in frames)))
stco=full("stco",u32(1,chunk_offset))
stbl=atom("stbl",stsd+stts+stsc+stsz+stco)
minf=atom("minf",vmhd+dinf+stbl)
mdia=atom("mdia",mdhd+hdlr+minf)
trak=atom("trak",tkhd+mdia)
moov=atom("moov",mvhd+trak)
path=Path("outputs/NIGHTRIDERCO/03_OBS/transitions/nightriderco-ice-wipe-QHD-60fps-alpha.mov")
path.write_bytes(ftyp+mdat+moov)
print(json.dumps({"file":str(path),"width":width,"height":height,"fps":fps,"duration":duration/fps,"frames":duration,"codec":"png ","depth":32,"bytes":path.stat().st_size,"cut_ms":600},indent=2))
