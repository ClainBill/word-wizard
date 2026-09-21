"""Composes the launcher-icon sources in assets/icon/ from the design pack in
assets/word-wizard-icon-pack/. Run from the repo root, then
`dart run flutter_launcher_icons`. Needs Pillow and numpy."""
from PIL import Image
import numpy as np
src=Image.open('assets/word-wizard-icon-pack/word-wizard-app-store-1024.png').convert('RGB')
a=np.array(src).astype(float)
# Background: the interior dark green, averaged over a glyph-free band.
bg=np.median(a[120:200,120:900].reshape(-1,3),axis=0)
print('bg', bg)
# Glyph alpha from brightness: cream and gold sit far above the green.
mx=a.max(axis=2)
alpha=np.clip((mx-95)/(170-95),0,1)
# The square's own edge highlight is a ring near the border; the glyph never reaches it.
alpha[:110,:]=0; alpha[915:,:]=0; alpha[:,:110]=0; alpha[:,915:]=0
# Un-mix the anti-aliased edge against the background.
al=alpha[...,None]
col=np.where(al>0.02,(a-(1-al)*bg)/np.maximum(al,0.02),a)
col=np.clip(col,0,255)
glyph=np.dstack([col,alpha*255]).astype(np.uint8)
ys,xs=np.where(alpha>0.5); x0,x1,y0,y1=xs.min(),xs.max(),ys.min(),ys.max()
print('glyph bbox',x0,x1,y0,y1, 'w',x1-x0,'h',y1-y0)
g=Image.fromarray(glyph,'RGBA').crop((x0,y0,x1+1,y1+1))
bgc=tuple(int(v) for v in bg)
hexbg='#%02X%02X%02X'%bgc; print('hex',hexbg)

def compose(size, glyph_frac, transparent=False):
    canvas=Image.new('RGBA',(size,size),(0,0,0,0) if transparent else bgc+(255,))
    gw,gh=g.size; scale=glyph_frac*size/max(gw,gh)
    gg=g.resize((round(gw*scale),round(gh*scale)),Image.LANCZOS)
    # The original sits a touch high (the hat); keep its vertical balance.
    cx=(size-gg.width)//2; cy=(size-gg.height)//2
    canvas.alpha_composite(gg,(cx,cy))
    return canvas

# iOS / legacy / store: the glyph at the pack's own proportion of the square
frac=max(x1-x0,y1-y0)/(967-55)
print('pack glyph fraction of square', frac)
compose(1024, frac).convert('RGB').save('assets/icon/icon.png')
# Adaptive foreground: flutter_launcher_icons insets this 16% per side, and the
# result must sit inside the 66/108 safe circle — ~70% of the source does.
compose(1024, 0.70, transparent=True).save('assets/icon/icon_foreground.png')
print('set adaptive_icon_background in pubspec.yaml to', hexbg)
