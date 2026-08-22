'use strict';
const { spawn, execFile } = require('child_process');
const { EventEmitter } = require('events');
const fs = require('fs');
const os = require('os');
const path = require('path');

const PROMPT_SENTINEL = 'Vos: ';

class MentisProcess extends EventEmitter {
  constructor({ bashPath, scriptPath, args, pidFile }) {
    super();
    this.bashPath = bashPath;
    this.scriptPath = scriptPath;
    this.args = args || [];
    // Registro de procesos de fondo (ver nv_track_bg_pid en nv-lib.sh): el motor bash anota acá
    // el PID de Windows de cada cosa que lanza con '&'. Es la unica lista confiable -- la
    // genealogia de procesos de Windows queda rota por el fork() emulado de MSYS, asi que no
    // hay forma de deducirlos desde afuera.
    this.pidFile = pidFile || path.join(os.tmpdir(), `mentis-bgpids-${process.pid}-${Date.now()}.txt`);
    this.child = null;
    this._pid = null;
    this.exited = false;
    this._outBuf = '';
    // Buffer del stderr. Ver _emitLines: sin esto, un chunk que corta una linea al medio
    // se emitia como dos eventos y el segundo dejaba de ser reconocible.
    this._errBuf = '';
    // Bug real (2026-07-15): mentis-chat.sh imprime su PRIMER "Vos: " apenas termina de
    // bootear (sourcing de libs, carga de capabilities), antes de que se haya leido ningun
    // mensaje real -- ese primer sentinel NO es un turno completado. Sin esto, el primer
    // mensaje mandado a una conversacion nueva se trataba como fin de turno de inmediato:
    // el renderer re-renderizaba el historial (todavia vacio) y borraba la burbuja
    // optimista, dando la sensacion de que el chat "se reiniciaba" y perdia el mensaje.
    this._hasSeenFirstPrompt = false;
  }

  start() {
    this.child = spawn(this.bashPath, [this.scriptPath,...this.args], {
      // NV_ANSWER_STDERR: pedirle al motor que vaya emitiendo la respuesta final por chunks
      // (lineas NVANSWER). Se prende ACA y no en mentis-chat.sh a proposito: es la app la unica
      // que sabe renderizarlas -- en una terminal serian ruido crudo en pantalla. Mismo criterio
      // con el que NVTHINK sigue apagado por defecto.
      env: {...process.env, MENTIS_PIDFILE: this.pidFile, NV_ANSWER_STDERR: '1' }
    });
    // Se guarda aparte: despues del 'exit' hace falta el PID para barrer los descendientes que
    // hayan quedado huerfanos, y para entonces child.pid ya no es confiable.
    this._pid = this.child.pid;
    this.child.stdout.on('data', (chunk) => this._onStdoutChunk(chunk.toString('utf-8')));
    this.child.stderr.on('data', (chunk) => this._emitLines(chunk.toString('utf-8')));
    this.child.on('exit', (code) => {
      this.exited = true;
      this._flushErrBuf();
      this.emit('exit', code);
    });
  }

  _onStdoutChunk(text) {
    this._outBuf += text;
    let idx;
    while ((idx = this._outBuf.indexOf('\n')) !== -1) {
      const line = this._outBuf.slice(0, idx);
      this._outBuf = this._outBuf.slice(idx + 1);
      this.emit('log', line);
    }
    // "Vos: " nunca trae salto de linea (es printf sin \n) -- se detecta por el contenido
    // restante en el buffer tras extraer las lineas completas, no por una linea completa.
    if (this._outBuf === PROMPT_SENTINEL) {
      this._outBuf = '';
      if (!this._hasSeenFirstPrompt) {
        this._hasSeenFirstPrompt = true;
        this.emit('ready');
      } else {
        this.emit('turn-complete');
      }
    }
  }

  _emitLines(text) {
    // BUFFER DE LINEA (2026-08-18). Antes esto partia por '\n' y emitia lo que hubiera, sin
    // guardar el resto. Un chunk de stderr que corta una linea al medio ("NVANSWER hol" en un
    // chunk y "a mundo\n" en el siguiente) salia como DOS eventos: el primero perdia su cola y el
    // segundo ya no matchea el ANSWER_MARKER de main.js, asi que se iba al panel de progreso como
    // ruido. Reproducido con esta misma clase antes de tocarla.
    // _onStdoutChunk buffereaba asi desde siempre; este camino nunca lo hizo.
    this._errBuf += text;
    let idx;
    while ((idx = this._errBuf.indexOf('\n')) !== -1) {
      const line = this._errBuf.slice(0, idx);
      this._errBuf = this._errBuf.slice(idx + 1);
      if (line.length > 0) this.emit('log', line);
    }
  }

  // Lo que quedo en el buffer sin salto final se emite al cerrar: si no, la ultima linea del
  // proceso -- que puede ser justo el motivo por el que murio -- se perderia en silencio.
  _flushErrBuf() {
    if (this._errBuf && this._errBuf.length > 0) {
      this.emit('log', this._errBuf);
      this._errBuf = '';
    }
  }

  send(message) {
    if (!this.child || this.exited) throw new Error('el proceso no esta corriendo');
    this.child.stdin.write(message + '\n');
  }

  stop(timeoutMs = 3000) {
    return new Promise((resolve) => {
      if (!this.child || this.exited) return resolve();
      const onExit = () => {
        clearTimeout(timer);
        resolve();
      };
      this.child.once('exit', onExit);
      this.child.stdin.write('salir\n');
      const timer = setTimeout(async () => {
        this.child.removeListener('exit', onExit);
        // Bug real encontrado en investigacion 2026-07-14 (docs oficiales de Node): Windows no
        // tiene señales POSIX reales, `child.kill('SIGTERM')` solo mata el proceso bash.exe
        // apuntado, sin propagar a los hijos que haya lanzado (git/curl/python de un `exec` en
        // curso) -- quedaban huerfanos si "salir" no llegaba a tiempo. Reusa forceKill(), que ya
        // usa `taskkill /T` (mata el arbol completo) en vez de duplicar la logica con un SIGTERM
        // mas debil.
        await this.forceKill();
        resolve();
      }, timeoutMs);
    });
  }

  // Descendientes REALES del proceso (cierre transitivo por ParentProcessId), consultados al
  // sistema en vez de confiar en `taskkill /T`. Ver ERR-034: /T recorre el arbol que Windows
  // conoce en ESE instante, y la emulacion de fork() de MSYS bash deja nietos (curl a la API,
  // python, nv-verify.sh lanzado con &) que /T no alcanza -- quedaban vivos gastando API
  // despues de "Frenar ya", sin ninguna forma de matarlos desde la UI.
  // Windows NO reparenta los huerfanos: ParentProcessId sigue apuntando al PID muerto, asi que
  // esto tambien encuentra descendientes DESPUES de que el padre murio (barrido post-mortem).
  _descendantPids(rootPid) {
    return new Promise((resolve) => {
      if (process.platform !== 'win32') return resolve([]);
      const ps = `$ErrorActionPreference='SilentlyContinue'
$all = Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId
$target = @(${rootPid}); $found = @()
do {
  $next = @($all | Where-Object { $target -contains $_.ParentProcessId } | Select-Object -ExpandProperty ProcessId)
  $next = @($next | Where-Object { $found -notcontains $_ -and $_ -ne ${rootPid} })
  $found += $next; $target = $next
} while ($next.Count -gt 0)
$found -join ','`;
      execFile(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', ps],
        { timeout: 8000 },
        (err, stdout) => {
          if (err) return resolve([]);
          const pids = String(stdout || '')
.trim()
.split(',')
.map((s) => parseInt(s.trim(), 10))
.filter((n) => Number.isInteger(n) && n > 0 && n !== rootPid);
          resolve([...new Set(pids)]);
        }
      );
    });
  }

  _taskkillPids(pids) {
    return new Promise((resolve) => {
      if (!pids.length) return resolve(0);
      const args = ['/F'];
      for (const p of pids) args.push('/PID', String(p));
      execFile('taskkill', args, () => resolve(pids.length));
    });
  }

  // PIDs de Windows que el motor bash anoto (nv_track_bg_pid). Se leen del pidFile, que es
  // append-only durante toda la vida del proceso.
  _trackedPids() {
    try {
      return [
...new Set(
          fs
.readFileSync(this.pidFile, 'utf-8')
.split('\n')
.map((l) => parseInt(l.trim(), 10))
.filter((n) => Number.isInteger(n) && n > 0)
        )
      ];
    } catch {
      return [];
    }
  }

  // Barrido de huerfanos: mata lo que haya quedado colgando de este proceso aunque el proceso
  // mismo ya haya muerto. Se llama tanto desde forceKill() como desde main.js cuando el proceso
  // termina por su cuenta (un crash a mitad de un turno dejaba los nietos vivos igual).
  // Dos fuentes, porque ninguna sola alcanza:
  //   - el registro explicito del motor bash (unica via para lo que lanza con '&' en MSYS), y
  //   - el cierre transitivo por PPID (para los procesos Windows normales, cuya genealogia si
  //     esta intacta: el propio bash.exe y lo que corra en primer plano).
  async sweepOrphans() {
    if (process.platform !== 'win32') return { ok: true, killed: 0 };
    const tracked = this._trackedPids();
    const descendants = this._pid ? await this._descendantPids(this._pid) : [];
    const pids = [...new Set([...tracked,...descendants])].filter((p) => p !== this._pid);
    if (!pids.length) return { ok: true, killed: 0 };
    // /T ademas del PID suelto: si ese proceso tiene hijos VIVOS con genealogia intacta
    // (ej. el curl que nv-verify.sh esta corriendo ahora), se van con el.
    await new Promise((resolve) => {
      const args = ['/F', '/T'];   // /T es global al comando, no por /PID
      for (const p of pids) args.push('/PID', String(p));
      execFile('taskkill', args, () => resolve());
    });
    return { ok: true, killed: pids.length, pids };
  }

  // Frenado de emergencia ("modo sin frenos"): a diferencia de stop() (graceful, espera a que
  // el turno termine o hace SIGTERM despues de un timeout), esto mata el arbol de procesos YA,
  // sin esperar. Orden importante: se toma el censo de descendientes ANTES de matar la raiz
  // (una vez muerta, el arbol es mas dificil de reconstruir) y se mata de las hojas a la raiz.
  async forceKill() {
    if (!this.child || this.exited) {
      // Aunque el bash ya haya muerto, sus nietos pueden seguir vivos (ese ERA el bug).
      const swept = await this.sweepOrphans();
      return { ok: true, method: 'already-exited', orphansKilled: swept.killed };
    }
    const pid = this.child.pid;
    if (process.platform !== 'win32') {
      try {
        this.child.kill('SIGKILL');
        return { ok: true, method: 'SIGKILL' };
      } catch (e) {
        return { ok: false, method: 'SIGKILL', error: String(e.message || e) };
      }
    }
    // Primero los de fondo (los que gastan API y sobreviven al /T), despues la raiz.
    const swept = await this.sweepOrphans();
    const rootErr = await new Promise((resolve) => {
      execFile('taskkill', ['/F', '/T', '/PID', String(pid)], (err) => resolve(err));
    });
    // Segunda pasada: algo lanzado JUSTO mientras se mataba lo anterior pudo escaparse.
    const swept2 = await this.sweepOrphans();
    return {
      ok: !rootErr,
      method: 'taskkill+sweep',
      orphansKilled: (swept.killed || 0) + (swept2.killed || 0),
      error: rootErr ? String(rootErr.message || rootErr) : null
    };
  }
}

module.exports = { MentisProcess, PROMPT_SENTINEL };
