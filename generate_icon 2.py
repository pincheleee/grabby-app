#!/usr/bin/env python3
"""Generate a simple Grabby icon as 512x512 PNG."""
import struct, zlib, os, math
os.makedirs("assets", exist_ok=True)
S = 512

def png(w, h, px):
    def ch(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''
    for y in range(h):
        raw += b'\x00'
        for x in range(w):
            i = (y*w+x)*4
            raw += px[i:i+4]
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB',w,h,8,6,0,0,0)) + ch(b'IDAT', zlib.compress(raw,9)) + ch(b'IEND', b'')

px = bytearray(S*S*4)
for y in range(S):
    for x in range(S):
        i=(y*S+x)*4
        nx,ny=x/S,y/S
        m=0.06; cr=0.22
        inside=True
        if nx<m or nx>1-m or ny<m or ny>1-m:
            inside=False
        else:
            ix=(nx-m)/(1-2*m); iy=(ny-m)/(1-2*m); r2=cr/(1-2*m)
            cx2=cy2=None
            if ix<r2 and iy<r2: cx2,cy2=r2,r2
            elif ix>1-r2 and iy<r2: cx2,cy2=1-r2,r2
            elif ix<r2 and iy>1-r2: cx2,cy2=r2,1-r2
            elif ix>1-r2 and iy>1-r2: cx2,cy2=1-r2,1-r2
            if cx2 is not None and ((ix-cx2)**2+(iy-cy2)**2)**.5>r2: inside=False

        if not inside:
            px[i:i+4]=b'\x00\x00\x00\x00'; continue

        # Dark bg with subtle gradient
        br=int(12+8*ny); bg=int(12+8*ny); bb=int(14+10*ny)

        # Down arrow
        cx,cy=0.5,0.42
        bar_w,bar_t,bar_b=0.09,0.20,0.52
        in_bar=(abs(nx-cx)<bar_w/2 and bar_t<ny<bar_b)

        # Triangle head
        tt,tb,tw=0.44,0.64,0.28
        in_tri=False
        if tt<ny<tb:
            t=(ny-tt)/(tb-tt)
            hw=tw/2*(1-t)
            in_tri=abs(nx-cx)<hw

        # Tray
        ty,th,twid,tsw,tsh=0.72,0.045,0.42,0.045,0.14
        in_tray=abs(nx-cx)<twid/2 and abs(ny-ty)<th/2
        in_tl=abs(nx-(cx-twid/2+tsw/2))<tsw/2 and ty-tsh<ny<ty
        in_tr=abs(nx-(cx+twid/2-tsw/2))<tsw/2 and ty-tsh<ny<ty

        if in_bar or in_tri:
            t=max(0,min(1,(ny-.2)/.5))
            px[i:i+4]=bytes([int(255),int(80+60*t),int(40+20*t),255])
        elif in_tray or in_tl or in_tr:
            px[i:i+4]=bytes([180,90,50,255])
        else:
            px[i:i+4]=bytes([br,bg,bb,255])

with open("assets/icon_512.png","wb") as f:
    f.write(png(S,S,bytes(px)))
print("  ✅ Icon generated")
