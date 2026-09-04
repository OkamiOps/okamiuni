#!/usr/bin/env python3
"""Check catalog parity, interpolation placeholders and literal L10n.tr coverage.

Run from any directory. Only interface strings explicitly passed to L10n.tr
are checked; user content, wire values and hidden prompts are not localized.
"""
import re,json,pathlib
# Match ordinary strings including nested interpolation; skip comments and multiline literals.
def literals(s):
 i=0
 while i<len(s):
  if s.startswith('//',i):
   j=s.find('\n',i); i=len(s) if j<0 else j+1; continue
  if s.startswith('/*',i):
   depth=1;i+=2
   while i<len(s) and depth:
    if s.startswith('/*',i):depth+=1;i+=2
    elif s.startswith('*/',i):depth-=1;i+=2
    else:i+=1
   continue
  if s.startswith('"""',i):
   j=s.find('"""',i+3);i=len(s) if j<0 else j+3;continue
  if s[i]!='"':i+=1;continue
  a=i;i+=1
  while i<len(s):
   if s.startswith('\\(',i):
    d=1;i+=2
    while i<len(s) and d:
     if s[i]=='(':d+=1
     elif s[i]==')':d-=1
     i+=1
   elif s[i]=='\\':i+=2
   elif s[i]=='"':i+=1;break
   else:i+=1
  yield a,i,s[a+1:i-1]
def key(t):
 out='';i=0;n=0
 while i<len(t):
  if t.startswith('\\(',i):
   d=1;i+=2
   while i<len(t) and d:
    if t[i]=='(':d+=1
    elif t[i]==')':d-=1
    i+=1
   out+='{'+str(n)+'}';n+=1
  else:out+=t[i];i+=1
 return out.replace('\\n','\n').replace('\\"','"').replace('\\t','\t').replace('\\\\','\\')

def main():
 root = pathlib.Path(__file__).resolve().parents[1]
 resources = root / 'Packages/UNICore/Sources/UNICore/Resources'
 catalogs = {}
 errors = []
 for language in ['pt-BR', 'en', 'de', 'fr']:
  entries = {}
  for line in (resources / (language + '.lproj') / 'Localizable.strings').read_text().splitlines():
   if not line.strip() or line.lstrip().startswith('//'): continue
   match = re.fullmatch(r'("(?:[^"\\]|\\.)*") = ("(?:[^"\\]|\\.)*");', line)
   if not match: raise ValueError(f'Invalid catalog line: {language}: {line}')
   original, translated = map(json.loads, match.groups())
   if original in entries: errors.append(f'Duplicate key in {language}: {original}')
   entries[original] = translated
   if sorted(re.findall(r'\{\d+\}', original)) != sorted(re.findall(r'\{\d+\}', translated)):
    errors.append(f'Placeholder mismatch in {language}: {original}')
  catalogs[language] = entries
 base = catalogs['pt-BR']
 for language, entries in catalogs.items():
  if entries.keys() != base.keys(): errors.append(f'Catalog keys differ for {language}')
  for original, translated in entries.items():
   if not translated.strip(): errors.append(f'Empty translation in {language}: {original}')
 references = 0
 paths = list((root / 'App').rglob('*.swift'))
 for package in (root / 'Packages').iterdir():
  if (package / 'Sources').is_dir(): paths.extend((package / 'Sources').rglob('*.swift'))
 for path in paths:
  source = path.read_text()
  for start, end, literal in literals(source):
   if re.search(r'L10n\.tr\(\s*$', source[max(0, start - 40):start]):
    references += 1
    original = key(literal)
    if original not in base:
     line = source.count('\n', 0, start) + 1
     errors.append(f'{path.relative_to(root)}:{line}: missing {original!r}')
 if errors:
  print('\n'.join(errors)); return 1
 print(f'OK: {len(base)} keys in 4 languages; {references} localized source references; placeholders match.')
 return 0

if __name__ == '__main__':
 raise SystemExit(main())
