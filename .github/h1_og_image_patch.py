from pathlib import Path
p=Path('humanity-live.html')
s=p.read_text(encoding='utf-8')
old='<meta property="og:url" content="https://ozdalmete-netizen.github.io/humanity/humanity-live.html" />\n<meta name="twitter:card" content="summary" />'
new='<meta property="og:url" content="https://ozdalmete-netizen.github.io/humanity/humanity-live.html" />\n<meta property="og:image" content="https://ozdalmete-netizen.github.io/humanity/humanity-social-launch.jpg" />\n<meta property="og:image:width" content="1000" />\n<meta property="og:image:height" content="525" />\n<meta name="twitter:card" content="summary_large_image" />\n<meta name="twitter:image" content="https://ozdalmete-netizen.github.io/humanity/humanity-social-launch.jpg" />'
if s.count(old)!=1: raise SystemExit(f'expected 1 social anchor, found {s.count(old)}')
s=s.replace(old,new,1)
s=s.replace('V5.8.11-SOCIAL-META-20260826','V5.8.12-LAUNCH-CARD-20260826')
p.write_text(s,encoding='utf-8')
