from PIL import Image, ImageDraw
S=4; W=1024*S
BG=(61,214,163); FG=(11,11,15)
def P(pts,dy): return [(x*S,(y+dy)*S) for x,y in pts]
def render(path,bg=BG,fg=FG,dy=-16):
    img=Image.new('RGB',(W,W),bg); d=ImageDraw.Draw(img)
    def rr(x0,y0,x1,y1,r=16): d.rounded_rectangle([x0*S,(y0+dy)*S,x1*S,(y1+dy)*S],radius=r*S,fill=fg)
    rr(200,724,824,824); rr(200,588,824,688); rr(200,452,824,552)
    d.polygon(P([(404,440),(512,536),(620,440)],dy),fill=bg)
    t=74
    d.polygon(P([(322,226),(322+t*1.55,226),(512,388),(702-t*1.55,226),(702,226),(512,398+t*0.95)],dy),fill=fg)
    img.resize((1024,1024),Image.LANCZOS).save(path)
render('icon.png')
