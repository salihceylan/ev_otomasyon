'use strict';

// Test yardimcisi: bir JavaScript kaynak metnindeki dize/sablon literallerini (yorumlar ve duzenli ifadeler
// atlanarak) satir numarasi ve solundaki baglamla listeler. Tam bir ayristirici DEGILDIR; yalnizca
// "kullaniciya donen metin" taramasi icin yeterli, basit bir sozcuk ayirici (lexer).
//
// Kullanim: stringLiterals(kaynak) -> [{ type: 'str'|'tpl', line, raw, ctx }]

/**
 * @param {string} src
 * @returns {{type:string, line:number, raw:string, ctx:string}[]}
 */
function stringLiterals(src) {
  const out = [];
  const n = src.length;
  let i = 0;
  let line = 1;
  let prev = '';

  // "/" bolme mi, duzenli ifade baslangici mi? (onceki anlamli token'a gore)
  const regexAllowed = () => {
    if (prev === '') return true;
    const last = prev.slice(-1);
    if (/[)\]}A-Za-z0-9_$'"`]/.test(last)) {
      return /^(return|typeof|case|in|of|delete|void|throw|new|else|do)$/.test(prev);
    }
    return true;
  };

  function readTemplate() {
    // i: acilis backtick'inden SONRA
    let raw = '';
    while (i < n) {
      const c = src[i];
      if (c === '\\') {
        raw += c + (src[i + 1] || '');
        if (src[i + 1] === '\n') line++;
        i += 2;
        continue;
      }
      if (c === '`') {
        i++;
        return raw;
      }
      if (c === '$' && src[i + 1] === '{') {
        raw += '${';
        i += 2;
        let depth = 1;
        while (i < n && depth > 0) {
          const d = src[i];
          if (d === '{') { depth++; raw += d; i++; continue; }
          if (d === '}') { depth--; raw += d; i++; continue; }
          if (d === '\'' || d === '"') {
            const q = d;
            raw += d;
            i++;
            while (i < n && src[i] !== q) {
              if (src[i] === '\\') { raw += src[i]; i++; }
              raw += src[i];
              i++;
            }
            raw += q;
            i++;
            continue;
          }
          if (d === '`') {
            i++;
            raw += '`' + readTemplate() + '`';
            continue;
          }
          if (d === '\n') line++;
          raw += d;
          i++;
        }
        continue;
      }
      if (c === '\n') line++;
      raw += c;
      i++;
    }
    return raw;
  }

  const leftContext = (index) => src.slice(Math.max(0, index - 80), index).replace(/\s+/g, ' ');

  while (i < n) {
    const c = src[i];
    if (c === '\n') { line++; i++; continue; }
    if (/\s/.test(c)) { i++; continue; }
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && src[i + 1] === '*') {
      i += 2;
      while (i < n && !(src[i] === '*' && src[i + 1] === '/')) {
        if (src[i] === '\n') line++;
        i++;
      }
      i += 2;
      continue;
    }
    if (c === '\'' || c === '"') {
      const q = c;
      const startLine = line;
      const startIndex = i;
      let raw = '';
      i++;
      while (i < n && src[i] !== q) {
        if (src[i] === '\\') { raw += src[i] + (src[i + 1] || ''); i += 2; continue; }
        raw += src[i];
        i++;
      }
      i++;
      out.push({ type: 'str', line: startLine, raw, ctx: leftContext(startIndex) });
      prev = q;
      continue;
    }
    if (c === '`') {
      const startLine = line;
      const startIndex = i;
      i++;
      const raw = readTemplate();
      out.push({ type: 'tpl', line: startLine, raw, ctx: leftContext(startIndex) });
      prev = '`';
      continue;
    }
    if (c === '/' && regexAllowed()) {
      i++;
      let inClass = false;
      while (i < n) {
        const d = src[i];
        if (d === '\\') { i += 2; continue; }
        if (d === '[') inClass = true;
        else if (d === ']') inClass = false;
        else if (d === '/' && !inClass) break;
        else if (d === '\n') break;
        i++;
      }
      i++;
      while (i < n && /[a-z]/.test(src[i])) i++;
      prev = '/regex/';
      continue;
    }
    if (/[A-Za-z0-9_$]/.test(c)) {
      let w = '';
      while (i < n && /[A-Za-z0-9_$]/.test(src[i])) { w += src[i]; i++; }
      prev = w;
      continue;
    }
    prev = c;
    i++;
  }
  return out;
}

module.exports = { stringLiterals };
