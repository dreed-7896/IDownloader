from PIL import Image, ImageDraw
S=4; W=1024*S
def P(pts,dy=0,dx=0): return [((x+dx)*S,(y+dy)*S) for x,y in pts]
def variant(path, bg, slabs, chev, notch_bg=None, dy=-10):
    img=Image.new('RGB',(W,W),bg); d=ImageDraw.Draw(img)
    def rr(x0,y0,x1,y1,c,r=20): d.rounded_rectangle([x0*S,(y0+dy)*S,x1*S,(y1+dy)*S],radius=r*S,fill=c)
    # slabs bottom->top, narrowing for depth
    rr(208,722,816,820,slabs[2])
    rr(232,598,792,696,slabs[1])
    rr(256,474,768,572,slabs[0])
    d.polygon(P([(420,462),(512,546),(604,462)],dy),fill=notch_bg or bg)
    t=78
    d.polygon(P([(338,212),(338+t*1.5,212),(512,372),(686-t*1.5,212),(686,212),(512,378+t*0.95)],dy),fill=chev)
    img.resize((1024,1024),Image.LANCZOS).save(path)
mint=(61,214,163)
mint=(61,214,163)
# Master icon: dark field, mint slabs darkening toward the bottom, white chevron.
variant('icon.png',(11,11,15),[mint,(42,150,114),(30,98,76)],(244,244,246))
