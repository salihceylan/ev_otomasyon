// Port kullanimi denetimi (up'tan once cakisma tespiti) ve portu kimin tuttugunu (yalniz bilgi icin) bulma.
import { execFileSync } from 'node:child_process';
import net from 'node:net';

/** Porta bind edilebiliyor mu? */
export function canBind(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.once('error', () => resolve(false));
    s.listen(port, host, () => s.close(() => resolve(true)));
  });
}

/** netstat ile belirtilen portu DINLEYEN surec(ler)i: [{pid, address}] (Windows; digerlerinde bos). */
export function listeningOn(port) {
  if (process.platform !== 'win32') return [];
  try {
    const out = execFileSync('netstat', ['-ano', '-p', 'TCP'], { encoding: 'utf8', windowsHide: true, timeout: 15000 });
    const res = [];
    for (const line of out.split(/\r?\n/)) {
      const m = /^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)/i.exec(line);
      if (m && Number(m[2]) === port) res.push({ address: m[1], pid: Number(m[3]) });
    }
    return res;
  } catch (_) {
    return [];
  }
}

/** PID'nin imaj adi (Windows tasklist). */
export function imageNameOf(pid) {
  if (process.platform !== 'win32') return '';
  try {
    const out = execFileSync('tasklist', ['/FI', `PID eq ${pid}`, '/FO', 'CSV', '/NH'], { encoding: 'utf8', windowsHide: true, timeout: 15000 });
    const m = /^"([^"]+)"/.exec(out.trim());
    return m ? m[1] : '';
  } catch (_) {
    return '';
  }
}

/**
 * Port meşgul mu ve kim tutuyor? (bind denemesi + netstat)
 * @returns {Promise<{busy:boolean, owners:{pid:number, image:string, address:string}[]}>}
 */
export async function portStatus(port, { ignorePids = [] } = {}) {
  const owners = listeningOn(port)
    .filter((o) => !ignorePids.includes(o.pid))
    .map((o) => ({ ...o, image: imageNameOf(o.pid) }));
  const bindable = await canBind(port);
  return { busy: owners.length > 0 || !bindable, owners };
}

export function describeOwners(owners) {
  if (!owners.length) return 'bilinmeyen surec';
  return owners.map((o) => `${o.image || 'surec'} (PID ${o.pid}, ${o.address})`).join(', ');
}
