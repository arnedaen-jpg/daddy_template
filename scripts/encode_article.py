#!/usr/bin/env python3
"""
零宽字符隐写工具

将域名列表编码为零宽 Unicode 字符，嵌入到普通文章中。
App 端下载文章后提取零宽字符即可还原域名。

编码规则：
  - U+200B (零宽空格)   = bit 0
  - U+200C (零宽非连接符) = bit 1
  - 多个域名用 \\n 分隔

使用方法：
  # 编码：将域名嵌入文章
  python3 scripts/encode_article.py encode \\
      --domains config/domain_fallback.json \\
      --article config/article_template.md \\
      --output config/output/healthy-life.md

  # 解码：从文章中提取域名（验证用）
  python3 scripts/encode_article.py decode --input config/output/healthy-life.md

  # 生成示例文章模板
  python3 scripts/encode_article.py gen-article --output config/article_template.md
"""

import argparse
import json
import os
import sys

ZW_SPACE = '\u200b'   # bit 0
ZW_NON_JOINER = '\u200c'  # bit 1


def domains_to_zwc(domains: list[str]) -> str:
    """将域名列表编码为零宽字符串"""
    payload = '\n'.join(domains)
    payload_bytes = payload.encode('utf-8')

    bits = ''.join(format(b, '08b') for b in payload_bytes)
    return bits.replace('0', ZW_SPACE).replace('1', ZW_NON_JOINER)


def zwc_to_domains(text: str) -> list[str]:
    """从文本中提取零宽字符并解码为域名列表"""
    zwc_chars = [c for c in text if c in (ZW_SPACE, ZW_NON_JOINER)]
    if not zwc_chars:
        return []

    bits = ''.join('0' if c == ZW_SPACE else '1' for c in zwc_chars)

    # 截断到 8 的整数倍
    bits = bits[:len(bits) - len(bits) % 8]
    if not bits:
        return []

    raw_bytes = bytes(int(bits[i:i+8], 2) for i in range(0, len(bits), 8))
    payload = raw_bytes.decode('utf-8')
    return [d for d in payload.split('\n') if d]


def encode_into_article(article_text: str, domains: list[str],
                        insert_after_paragraph: int = 0) -> str:
    """将域名编码后嵌入文章指定段落末尾"""
    zwc = domains_to_zwc(domains)

    paragraphs = article_text.split('\n\n')
    if insert_after_paragraph >= len(paragraphs):
        insert_after_paragraph = 0

    paragraphs[insert_after_paragraph] += zwc
    return '\n\n'.join(paragraphs)


def cmd_encode(args):
    with open(args.domains, 'r', encoding='utf-8') as f:
        data = json.load(f)
    domains = data.get('domains', [])
    if not domains:
        print('错误: 域名列表为空', file=sys.stderr)
        sys.exit(1)

    with open(args.article, 'r', encoding='utf-8') as f:
        article = f.read()

    result = encode_into_article(article, domains, args.paragraph)

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(result)

    payload_bytes = '\n'.join(domains).encode('utf-8')
    zwc_count = len(payload_bytes) * 8

    print(f'✓ 编码成功: {args.output}')
    print(f'  域名数量: {len(domains)}')
    for d in domains:
        print(f'    - {d}')
    print(f'  零宽字符: {zwc_count} 个')
    print(f'  文件大小: {os.path.getsize(args.output)} bytes')
    print(f'\n后续操作: 将 {args.output} 上传到 CDN')


def cmd_decode(args):
    with open(args.input, 'r', encoding='utf-8') as f:
        text = f.read()

    domains = zwc_to_domains(text)
    if not domains:
        print('未检测到隐藏的域名数据')
        sys.exit(1)

    print(f'✓ 解码成功，发现 {len(domains)} 个域名:')
    for d in domains:
        print(f'  - {d}')

    # 验证文章可见内容未被破坏
    visible = ''.join(c for c in text if c not in (ZW_SPACE, ZW_NON_JOINER))
    print(f'\n文章可见字符数: {len(visible)}')


def cmd_gen_article(args):
    article = """# 如何保持健康的生活方式

在现代社会中，越来越多的人开始关注自己的身体健康。随着生活节奏的加快，很多人忽视了日常的健康管理，导致各种慢性疾病的发生率逐年上升。本文将从饮食、运动、睡眠三个方面，分享一些实用的健康建议。

## 均衡饮食

均衡饮食是健康的基础。营养学家建议，每天的饮食应该包含足够的蛋白质、碳水化合物、脂肪、维生素和矿物质。新鲜的蔬菜和水果应该占据每日饮食的重要部分。同时，应该减少加工食品和含糖饮料的摄入，选择更天然、更健康的食物。

## 适度运动

适度运动对身体健康至关重要。世界卫生组织建议，成年人每周应进行至少150分钟的中等强度有氧运动，或75分钟的高强度有氧运动。散步、慢跑、游泳、骑自行车都是很好的运动方式。对于长期久坐的上班族，建议每隔一小时起身活动几分钟。

## 良好睡眠

良好的睡眠习惯同样不可忽视。研究表明，成年人每天需要7到9小时的睡眠。保持规律的作息时间，创造舒适的睡眠环境，避免睡前使用电子设备，都有助于提高睡眠质量。充足的睡眠不仅能恢复体力，还能增强免疫力，改善记忆力。

## 心理健康

心理健康同样重要。在忙碌的生活中，我们应该学会放松自己，培养一些兴趣爱好，保持积极乐观的心态。与家人朋友保持良好的社交关系，也是维护心理健康的重要方式。

---

总之，健康的生活方式需要长期坚持。从今天开始，让我们一起关注自己的身体，养成良好的生活习惯，享受更高质量的生活。"""

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w', encoding='utf-8') as f:
        f.write(article)
    print(f'✓ 文章模板已生成: {args.output}')


def main():
    parser = argparse.ArgumentParser(description='零宽字符隐写工具')
    subparsers = parser.add_subparsers(dest='command')

    # encode
    p_enc = subparsers.add_parser('encode', help='将域名编码嵌入文章')
    p_enc.add_argument('--domains', required=True, help='域名列表 JSON 文件')
    p_enc.add_argument('--article', required=True, help='文章模板文件')
    p_enc.add_argument('--output', required=True, help='输出文件路径')
    p_enc.add_argument('--paragraph', type=int, default=0,
                       help='嵌入到第几段末尾 (0-based, 默认第一段)')

    # decode
    p_dec = subparsers.add_parser('decode', help='从文章中提取域名')
    p_dec.add_argument('--input', required=True, help='含隐写数据的文章文件')

    # gen-article
    p_gen = subparsers.add_parser('gen-article', help='生成示例文章模板')
    p_gen.add_argument('--output', default='config/article_template.md',
                       help='输出路径')

    args = parser.parse_args()
    if args.command == 'encode':
        cmd_encode(args)
    elif args.command == 'decode':
        cmd_decode(args)
    elif args.command == 'gen-article':
        cmd_gen_article(args)
    else:
        parser.print_help()


if __name__ == '__main__':
    main()
