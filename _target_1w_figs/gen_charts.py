#!/usr/bin/env python3
"""Generate 汇总1w report charts from sheet snapshot."""
import os
import numpy as np
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm

font_path = '/System/Library/Fonts/Hiragino Sans GB.ttc'
fm.fontManager.addfont(font_path)
plt.rcParams['font.family'] = 'Hiragino Sans GB'
plt.rcParams['axes.unicode_minus'] = False
plt.rcParams['figure.facecolor'] = 'white'

OUT = os.path.dirname(os.path.abspath(__file__))
months = ['8月', '9月', '10月', '11月', '12月']
months_q = ['9月', '10月', '11月', '12月']

C_PEAK, C_VOL = '#1A5CFF', '#F57C00'
C_SHARE, C_SHARE2 = '#0D9488', '#6366F1'
INIT = {'投流': '#2563EB', '调度': '#0D9488', '电销': '#F59E0B', '裂变': '#EC4899'}
NEW, RET = '#3B82F6', '#94A3B8'


def save(fig, name):
    path = os.path.join(OUT, name)
    fig.savefig(path, dpi=160, bbox_inches='tight', pad_inches=0.25)
    plt.close(fig)
    print('wrote', path)


# ---- data from 汇总1w (latest) ----
peak = [0.0462, 0.10, 0.21, 0.46, 1.00]
vol = [0.6165, 2.19, 4.88, 10.18, 22.69]
peak_share = [0.52, 0.42, 0.80, 1.40, 2.50]
vol_share = [0.42, 0.39, 0.72, 1.32, 2.33]

lf = [0.26, 0.70, 1.67, 4.24]
dx = [0.36, 0.83, 1.80, 4.18]
tl = [1.00, 2.11, 4.21, 9.03]
dd = [0.57, 1.24, 2.49, 5.25]

shares = {
    '投流': [45.68, 43.19, 41.34, 39.79],
    '调度': [25.83, 25.51, 24.50, 23.13],
    '电销': [16.56, 17.03, 17.71, 18.41],
    '裂变': [11.93, 14.28, 16.45, 18.67],
}

lf_new = [0.0063, 0.11, 0.29, 0.61, 1.36]
lf_ret = [0.0002, 0.15, 0.40, 1.06, 2.87]
lf_share = [1.05, 11.93, 14.28, 16.45, 18.67]

data = {
    '投流': {'new': [0.0005, 0.24, 0.49, 0.92, 1.81], 'ret': [0.0129, 0.76, 1.62, 3.29, 7.21]},
    '调度': {'new': [0.0359, 0.18, 0.34, 0.51, 1.13], 'ret': [0.1853, 0.39, 0.90, 1.98, 4.11]},
    '电销': {'new': [0.0106, 0.11, 0.24, 0.51, 1.13], 'ret': [0.1504, 0.25, 0.59, 1.29, 3.04]},
}

# 电销漏斗 12月
sales_stages = ['外呼量', '接通量', '有效沟通', '企业线索', '企业认证']
sales_vals = [252380, 126190, 65619, 5250, 1624]
sales_rates = [None, '接通率 50%', '有效沟通率 52%', '线索获取率 8%', '线索注册率 31%']

# 电销新增货主 12月（更新后）
shipper_stages = ['注册货主', '认证货主', '发货货主', '成交货主']
shipper_vals = [5250, 1624, 370, 104]
shipper_rates = [None, '注册→认证 31%', '认证→发货 23%', '货主成交率 28%']

manpower = [17, 20, 22, 28, 48]
calls = [84451, 101507, 110693, 146001, 252380]

# Fig1
fig, ax1 = plt.subplots(figsize=(9.2, 4.6))
ax2 = ax1.twinx()
l1 = ax1.plot(months, peak, 'o-', color=C_PEAK, lw=2.4, ms=7, label='线上日峰值（万单）')
l2 = ax2.plot(months, vol, 's--', color=C_VOL, lw=2.2, ms=7, label='线上月运单（万单）')
ax1.fill_between(months, peak, color=C_PEAK, alpha=0.08)
for x, y in zip(months, peak):
    ax1.annotate(f'{y:g}', (x, y), textcoords='offset points', xytext=(0, 10), ha='center', fontsize=9, color=C_PEAK, fontweight='bold')
for x, y in zip(months[1:], vol[1:]):
    ax2.annotate(f'{y:g}', (x, y), textcoords='offset points', xytext=(0, -14), ha='center', fontsize=9, color=C_VOL)
ax1.set_ylabel('日峰值（万单）', color=C_PEAK)
ax2.set_ylabel('月运单（万单）', color=C_VOL)
ax1.set_ylim(0, 1.2)
ax2.set_ylim(0, 28)
ax1.set_title('图1  线上目标路径（1万峰值版）：日峰值 × 月运单', fontsize=13, pad=12, loc='left', fontweight='bold')
ax1.spines['top'].set_visible(False)
ax2.spines['top'].set_visible(False)
lines = l1 + l2
ax1.legend(lines, [l.get_label() for l in lines], loc='upper left', frameon=False)
save(fig, 'Fig1_峰值与月量路径.png')

# Fig2
fig, ax = plt.subplots(figsize=(9.2, 4.4))
ax.plot(months, peak_share, 'o-', color=C_SHARE, lw=2.4, ms=7, label='峰值线上占比')
ax.plot(months, vol_share, 's--', color=C_SHARE2, lw=2.2, ms=7, label='线上量占比')
ax.fill_between(months, peak_share, color=C_SHARE, alpha=0.08)
for x, y in zip(months, peak_share):
    ax.annotate(f'{y:.2f}%', (x, y), textcoords='offset points', xytext=(0, 9), ha='center', fontsize=9, color=C_SHARE, fontweight='bold')
ax.set_ylabel('占比（%）')
ax.set_ylim(0, 3.0)
ax.set_title('图2  线上占比跃迁：12月约 2.5%（峰值）/ 2.3%（量）', fontsize=13, pad=12, loc='left', fontweight='bold')
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.legend(loc='upper left', frameon=False)
save(fig, 'Fig2_线上占比跃迁.png')

# Fig3
fig, ax = plt.subplots(figsize=(9.2, 4.8))
x = np.arange(len(months_q))
w = 0.62
b0 = np.zeros(4)
for name, vals, c in [('投流', tl, INIT['投流']), ('调度', dd, INIT['调度']), ('电销', dx, INIT['电销']), ('裂变', lf, INIT['裂变'])]:
    ax.bar(x, vals, w, bottom=b0, color=c, label=name, edgecolor='white', linewidth=0.6)
    for i, v in enumerate(vals):
        if v >= 0.8:
            ax.text(x[i], b0[i] + v/2, f'{v:.2f}', ha='center', va='center', fontsize=8, color='white', fontweight='bold')
    b0 = b0 + np.array(vals)
totals = [2.19, 4.88, 10.18, 22.69]
for i, t in enumerate(totals):
    ax.text(x[i], t + 0.4, f'{t:.2f}', ha='center', fontsize=9, fontweight='bold')
ax.set_xticks(x)
ax.set_xticklabels(months_q)
ax.set_ylabel('运单量（万单）')
ax.set_title('图3  四举措运单堆叠（9–12月 · 合计约40万单）', fontsize=13, pad=12, loc='left', fontweight='bold')
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.legend(ncol=4, loc='upper left', frameon=False)
ax.set_ylim(0, 26)
save(fig, 'Fig3_四举措堆叠.png')

# Fig4
fig, ax = plt.subplots(figsize=(9.2, 4.6))
b0 = np.zeros(4)
for name in ['投流', '调度', '电销', '裂变']:
    vals = np.array(shares[name])
    ax.bar(x, vals, w, bottom=b0, color=INIT[name], label=name, edgecolor='white', linewidth=0.6)
    for i, v in enumerate(vals):
        ax.text(x[i], b0[i] + v/2, f'{v:.0f}%', ha='center', va='center', fontsize=8, color='white', fontweight='bold')
    b0 = b0 + vals
ax.set_xticks(x)
ax.set_xticklabels(months_q)
ax.set_ylabel('占线上（%）')
ax.set_ylim(0, 105)
ax.set_title('图4  四举措结构变化：投流托底略降，裂变后段抬升', fontsize=13, pad=12, loc='left', fontweight='bold')
ax.spines['top'].set_visible(False)
ax.spines['right'].set_visible(False)
ax.legend(ncol=4, loc='upper center', bbox_to_anchor=(0.5, 1.02), frameon=False)
save(fig, 'Fig4_四举措结构.png')


def funnel_chart(stages, vals, rates, colors, title, footnote, out_name, rate_color='#B45309', text_white_from=2):
    disp_w = [1.00, 0.82, 0.66, 0.48, 0.34][:len(stages)]
    if len(stages) == 4:
        disp_w = [1.00, 0.72, 0.58, 0.40]
    fig, ax = plt.subplots(figsize=(9.2, 5.0 if len(stages) == 5 else 4.8))
    n = len(stages)
    for i, (s, v, w, r, c) in enumerate(zip(stages, vals, disp_w, rates, colors)):
        y = n - i - 1
        left = (1 - w) / 2
        ax.barh(y, w, left=left, height=0.78 if n == 5 else 0.75, color=c, edgecolor='white', linewidth=1.5, zorder=2)
        label = f'{s}　{v:,.0f}' if v > 1000 else f'{s}　{v}'
        tc = 'white' if i >= text_white_from else '#1F2329'
        ax.text(0.5, y, label, ha='center', va='center', fontsize=12, fontweight='bold', color=tc, zorder=3)
        if r:
            ax.text(0.95, y + 0.38, r, ha='left', va='center', fontsize=9, color=rate_color)
    ax.set_xlim(-0.05, 1.2)
    ax.set_ylim(-0.65, n - 0.25)
    ax.axis('off')
    ax.set_title(title, fontsize=13, pad=10, loc='left', fontweight='bold')
    ax.text(0.0, -0.08, footnote, transform=ax.transAxes, fontsize=9, color='#8F959E', va='top')
    save(fig, out_name)


funnel_chart(
    sales_stages, sales_vals, sales_rates,
    ['#FEF3C7', '#FDE68A', '#FBBF24', '#F59E0B', '#D97706'],
    '图5  电销销售漏斗（12月目标）',
    '口径：外呼→接通→有效沟通→线索→认证｜配套人力约48人、外呼约25万通\n最大跌落：有效沟通→线索（约8%）；条宽为阶梯示意，绝对量以标注为准。',
    'Fig5_电销销售漏斗.png',
)

funnel_chart(
    shipper_stages, shipper_vals, shipper_rates,
    ['#DBEAFE', '#93C5FD', '#3B82F6', '#1D4ED8'],
    '图6  电销·新增货主转化漏斗（12月目标）',
    '对应新增成交运单约 1.13 万单；中间环节认证→发货约 23%、成交率约 28%，需同步线索质量与运营承接。',
    'Fig6_电销新增货主漏斗.png',
    rate_color='#1E40AF', text_white_from=2,
)

# Fig7
fig, (axa, axb) = plt.subplots(1, 2, figsize=(10.2, 4.4), gridspec_kw={'width_ratios': [1.2, 1]})
xa = np.arange(len(months))
axa.bar(xa, lf_ret, 0.58, color=RET, label='留存', edgecolor='white')
axa.bar(xa, lf_new, 0.58, bottom=lf_ret, color=INIT['裂变'], label='新增', edgecolor='white')
for i, t in enumerate([a+b for a,b in zip(lf_new, lf_ret)]):
    if t >= 0.2:
        axa.text(i, t + 0.08, f'{t:.2f}', ha='center', fontsize=8, fontweight='bold')
axa.set_xticks(xa)
axa.set_xticklabels(months)
axa.set_ylabel('运单（万单）')
axa.set_title('裂变运单：新老堆叠', fontsize=11, loc='left', fontweight='bold')
axa.legend(frameon=False, loc='upper left')
axa.spines['top'].set_visible(False)
axa.spines['right'].set_visible(False)
axb.plot(months, lf_share, 'o-', color=INIT['裂变'], lw=2.4, ms=7)
for x_, y in zip(months, lf_share):
    axb.annotate(f'{y:.1f}%', (x_, y), textcoords='offset points', xytext=(0, 8), ha='center', fontsize=8, color=INIT['裂变'], fontweight='bold')
axb.set_ylabel('占线上（%）')
axb.set_ylim(0, 22)
axb.set_title('裂变占线上结构抬升', fontsize=11, loc='left', fontweight='bold')
axb.spines['top'].set_visible(False)
axb.spines['right'].set_visible(False)
fig.suptitle('图7  裂变：从近空基线到后段结构抬升（占线上→约19%）', fontsize=13, fontweight='bold', x=0.02, ha='left')
fig.tight_layout(rect=[0, 0.02, 1, 0.92])
save(fig, 'Fig7_裂变新老与占比.png')

# Fig8
fig, axes = plt.subplots(1, 3, figsize=(11.0, 4.0))
for ax, name in zip(axes, ['投流', '调度', '电销']):
    n, r = data[name]['new'], data[name]['ret']
    xa = np.arange(len(months))
    ax.bar(xa, r, 0.58, color=RET, label='留存', edgecolor='white')
    ax.bar(xa, n, 0.58, bottom=r, color=INIT[name], label='新增', edgecolor='white')
    ax.set_xticks(xa)
    ax.set_xticklabels(months, fontsize=8)
    ax.set_title(name, fontsize=12, fontweight='bold', color=INIT[name])
    ax.spines['top'].set_visible(False)
    ax.spines['right'].set_visible(False)
    if name == '投流':
        ax.legend(frameon=False, fontsize=8, loc='upper left')
        ax.set_ylabel('运单（万单）')
fig.suptitle('图8  投流 / 调度 / 电销：新老运单路径（留存托底，新增后段放量）', fontsize=13, fontweight='bold', x=0.02, ha='left')
fig.tight_layout(rect=[0, 0.02, 1, 0.90])
save(fig, 'Fig8_投流调度电销新老.png')

# Fig9
fig, ax1 = plt.subplots(figsize=(9.0, 4.2))
ax2 = ax1.twinx()
ax1.bar(months, manpower, color='#FBBF24', width=0.55, label='电销人力（人）', alpha=0.9)
ax2.plot(months, [c/10000 for c in calls], 'o-', color='#B45309', lw=2.2, ms=7, label='外呼量（万通）')
for x_, y in zip(months, manpower):
    ax1.text(x_, y + 0.8, str(y), ha='center', fontsize=9, fontweight='bold', color='#92400E')
ax1.set_ylabel('人力（人）')
ax2.set_ylabel('外呼量（万通）')
ax1.set_ylim(0, 58)
ax2.set_ylim(0, 30)
ax1.set_title('图9  电销资源爬坡：人力 17→48，外呼约 8.4万→25.2万', fontsize=13, pad=12, loc='left', fontweight='bold')
ax1.spines['top'].set_visible(False)
ax2.spines['top'].set_visible(False)
h1, l1 = ax1.get_legend_handles_labels()
h2, l2 = ax2.get_legend_handles_labels()
ax1.legend(h1+h2, l1+l2, loc='upper left', frameon=False)
save(fig, 'Fig9_电销人力外呼.png')

print('ALL DONE')
