#!/usr/bin/env python3
from hashlib import sha256
from pathlib import Path

path = Path('/opt/hermes-webui/static/ui.js')
text = path.read_text()
replacements = [
    (
        """  // Default context window to 128K when not provided by backend
  const DEFAULT_CTX=128*1024;
  const ctxWindow=usage.context_length||DEFAULT_CTX;
""",
        """  const hasExplicitCtx=Number(usage.context_length)>0;
  const ctxWindow=hasExplicitCtx?Number(usage.context_length):0;
""",
    ),
    (
        """  const hasPromptTok=!!promptTok;
  const rawPct=hasPromptTok?Math.round((promptTok/ctxWindow)*100):0;
""",
        """  const hasPromptTok=!!promptTok;
  const hasMeasuredCtx=hasPromptTok&&hasExplicitCtx;
  const rawPct=hasMeasuredCtx?Math.round((promptTok/ctxWindow)*100):0;
""",
    ),
    (
        """  if(center) center.textContent=hasPromptTok?String(pct):'\\u00b7';
  const hasExplicitCtx=!!usage.context_length;
""",
        """  if(center) center.textContent=hasMeasuredCtx?String(pct):'\\u00b7';
""",
    ),
    (
        """  let label=hasPromptTok?`Context window ${pct}% used`:`${_fmtTokens(totalTok)} tokens used`;
  if(!hasExplicitCtx&&hasPromptTok) label+=' (est. 128K)';
  if(cost) label+=` \\u00b7 $${cost<0.01?cost.toFixed(4):cost.toFixed(2)}`;
  if(cacheText) label+=` \\u00b7 ${cacheText}`;
  el.setAttribute('aria-label',label);
  const usageText=hasPromptTok?(overflowed?`${rawPct}% used (context exceeded)`:`${pct}% used (${100-pct}% left)`):`${_fmtTokens(totalTok)} tokens used`;
  const tokensText=hasPromptTok?`${_fmtTokens(promptTok)} / ${_fmtTokens(ctxWindow)} tokens used`:`In: ${_fmtTokens(usage.input_tokens||0)} \\u00b7 Out: ${_fmtTokens(usage.output_tokens||0)}`;
""",
        """  let label=hasMeasuredCtx?`Context window ${pct}% used`:(hasPromptTok?`${_fmtTokens(promptTok)} prompt tokens used (context window unknown)`:`${_fmtTokens(totalTok)} tokens used`);
  if(cost) label+=` \\u00b7 $${cost<0.01?cost.toFixed(4):cost.toFixed(2)}`;
  if(cacheText) label+=` \\u00b7 ${cacheText}`;
  el.setAttribute('aria-label',label);
  const usageText=hasMeasuredCtx?(overflowed?`${rawPct}% used (context exceeded)`:`${pct}% used (${100-pct}% left)`):(hasPromptTok?`Context window unknown`:`${_fmtTokens(totalTok)} tokens used`);
  const tokensText=hasMeasuredCtx?`${_fmtTokens(promptTok)} / ${_fmtTokens(ctxWindow)} tokens used`:(hasPromptTok?`${_fmtTokens(promptTok)} prompt tokens used; context window unknown`:`In: ${_fmtTokens(usage.input_tokens||0)} · Out: ${_fmtTokens(usage.output_tokens||0)}`);
""",
    ),
]
for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected one source match, found {count}')
    text = text.replace(old, new, 1)
path.write_text(text)
got = sha256(path.read_bytes()).hexdigest()
expected = '103a13a48e1729e09678a2d4c96f0282e1cfebe8b8cfd11f1b0d95705738328f'
if got != expected:
    raise SystemExit(f'output checksum mismatch: {got} != {expected}')
