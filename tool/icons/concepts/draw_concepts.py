"""音狐图标方案概念图（纯几何绘制，输出 1024x1024 白底 PNG）。

四个方案：
  A 负空间狐头音符：实心狐头剪影，中间镂空白色八分音符
  B 音符双耳：八分音符，符干顶端分叉成两只狐耳
  C 侧脸狐狸：一笔画侧脸，尾巴收成音符
  D 圆徽章：深色圆底 + 白色狐头 + 橙色音符
所有几何函数均接收 1024 设计坐标，内部按 SS 放大。
"""
import math
import os

from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))
SS = 3
W = 1024
S = W * SS

INK = (31, 35, 40)
ORANGE = (255, 138, 61)
WHITE = (255, 255, 255)


def sc(v):
    return v * SS


def pt(p):
    return (sc(p[0]), sc(p[1]))


def smooth(pts, seg=28):
    """Catmull-Rom 样条采样。"""
    p = [pts[0]] + list(pts) + [pts[-1]]
    out = []
    for i in range(len(p) - 3):
        p0, p1, p2, p3 = p[i], p[i + 1], p[i + 2], p[i + 3]
        for j in range(seg):
            t = j / seg
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    out.append(tuple(pts[-1]))
    return out


def stroke(d, pts, width, color):
    """逐点画圆实现平滑粗线：PIL 的多点 line 在大线宽下会留接缝。
    先按线宽的 1/6 加密采样，避免稀疏点连成一串圆。"""
    step = max(1.0, width / 6)
    dense = [pts[0]]
    for a, b in zip(pts, pts[1:]):
        dist = math.hypot(b[0] - a[0], b[1] - a[1])
        n = max(1, int(dist / step))
        for i in range(1, n + 1):
            t = i / n
            dense.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    r = width / 2 * SS
    for x, y in dense:
        cx, cy = sc(x), sc(y)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)


def rot_ellipse(img, center, rx, ry, angle, color):
    size = int(max(rx, ry) * 2 * SS + 12)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.ellipse([size / 2 - rx * SS, size / 2 - ry * SS,
                size / 2 + rx * SS, size / 2 + ry * SS], fill=color + (255,))
    layer = layer.rotate(angle, resample=Image.BICUBIC, expand=False)
    img.paste(layer, (int(center[0] * SS - size / 2),
                      int(center[1] * SS - size / 2)), layer)


def fox_note(img, d, cx, cy, k, face, note, ear=None):
    """狐头 + 镂空音符。(cx,cy) 为脸中心，k 为缩放。"""
    ear = ear or face

    def P(x, y):
        return (cx + (x - 512) * k, cy + (y - 570) * k)

    # 双耳（底边水平，尖略外倾）
    d.polygon([pt(P(360, 450)), pt(P(530, 450)), pt(P(330, 220))], fill=ear)
    d.polygon([pt(P(664, 450)), pt(P(494, 450)), pt(P(694, 220))], fill=ear)
    # 脸
    d.ellipse([*pt(P(312, 370)), *pt(P(712, 770))], fill=face)
    # 音符：符干
    d.rectangle([*pt(P(494, 410)), *pt(P(520, 672))], fill=note)
    # 音符：符头
    rot_ellipse(img, P(438, 660), 70 * k, 54 * k, -20, note)
    # 音符：符尾
    stroke(d, [P(518, 410), P(566, 424), P(600, 462), P(608, 512),
               P(592, 550), P(560, 568)], 26 * k, note)


def new_canvas():
    img = Image.new("RGB", (S, S), WHITE)
    return img, ImageDraw.Draw(img)


def save(img, name):
    img.resize((W, W), Image.LANCZOS).save(os.path.join(OUT, name))
    print("saved", name)


# ---------------- A 负空间狐头音符 ----------------
img, d = new_canvas()
fox_note(img, d, 512, 570, 1.0, INK, WHITE)
save(img, "concept_A_negative_note.png")

# ---------------- B 双耳音符 ----------------
img, d = new_canvas()
# 双耳底边压住符干顶端，与音符连成一个整体（四分音符 + 双耳）
d.polygon([pt((400, 460)), pt((520, 460)), pt((420, 288))], fill=INK)
d.polygon([pt((624, 460)), pt((504, 460)), pt((604, 288))], fill=ORANGE)
d.rounded_rectangle([*pt((492, 380)), *pt((532, 726))], radius=sc(20), fill=INK)
rot_ellipse(img, (446, 730), 92, 74, -18, INK)
save(img, "concept_B_note_ears.png")


# ---------------- C U 形狐脸 + 音符 ----------------
img, d = new_canvas()
# 双耳（实心）
d.polygon([pt((352, 486)), pt((404, 296)), pt((476, 470))], fill=INK)
d.polygon([pt((672, 486)), pt((620, 296)), pt((548, 470))], fill=ORANGE)
# U 形下巴（下半圆弧）
d.arc([sc(342), sc(368), sc(682), sc(708)], start=0, end=180, fill=INK,
      width=int(sc(42)))
# 音符：橙符头 + 符干
rot_ellipse(img, (470, 608), 62, 50, -18, ORANGE)
d.rounded_rectangle([*pt((516, 430)), *pt((550, 612))], radius=sc(17), fill=INK)
stroke(d, [(548, 442), (590, 468), (600, 512), (584, 546)], 30, INK)
save(img, "concept_C_outline_face.png")


# ---------------- D 圆徽章 ----------------
img, d = new_canvas()
d.ellipse([sc(512 - 336), sc(512 - 336), sc(512 + 336), sc(512 + 336)], fill=INK)
fox_note(img, d, 512, 545, 0.66, WHITE, ORANGE, ear=WHITE)
save(img, "concept_D_badge.png")
