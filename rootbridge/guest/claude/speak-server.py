#!/usr/bin/env python3
"""speak-server - Articulino for speak.py (termux-rootbridge, part of --voice).

Keeps the model and your voice loaded (loading takes about 5 s and 500 MB) and reads aloud for speak.py: a client connects
to the socket, sends UTF-8 text and closes its sending side; the server answers with raw audio (16 bit signed, mono,
24 kHz), sentence by sentence, and closes. One client at a time; when a client goes away (a stop ends the player), its
text ends at the next sentence. A new recording of the voice is loaded with the next text. The server ends itself after
IDLE_SECONDS without a client (RB_SPEAK_SERVER_IDLE, for the tests): first its socket goes, so the next text starts a new
server, then it answers the clients that connected just before.

  speak-server.py SOCKET MODEL_DIR VOICE_WAV [LOCK_FD]

LOCK_FD: speak.py's start lock (an flock), passed on open; the server holds it until its socket listens, so no second
server is started while it loads, even when a stop ends the speak.py that started it.

Runs with the Python of the Articulino venv (setup-guest.sh); speak.py starts it in its own session (a stop of the
player does not end it), its errors go to speak.py's log.
"""
import os
import socket
import sys

from articulino_onnx import TTS

IDLE_SECONDS = float(os.environ.get("RB_SPEAK_SERVER_IDLE", 1800))
THREADS = 4   # more are not faster on the A9
SEED = 1      # the same text sounds the same every time


def serve(path, model, voice, lock_fd=None):
    tts = TTS.from_pretrained(model, precision="int8", threads=THREADS)
    voice_mtime = os.stat(voice).st_mtime
    tts.set_voice(voice)
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        os.unlink(path)   # one left by a server that was killed; under the start lock no other server binds
    except FileNotFoundError:
        pass
    os.umask(0o077)
    srv.bind(path)
    srv.listen(4)
    mine = os.stat(path).st_ino
    if lock_fd is not None:
        os.close(int(lock_fd))   # it listens: the next start finds it

    def answer(conn):
        nonlocal voice_mtime
        with conn:
            conn.settimeout(None)
            text = b""
            while True:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                text += chunk
            if not text:
                return   # a touch of the hook of a prompt (speak.py warm_server): it only keeps the server alive
            try:
                mtime = os.stat(voice).st_mtime
                if mtime != voice_mtime:
                    tts.set_voice(voice)
                    voice_mtime = mtime
                language = "de"   # speak.py sends another language first: \x01<language>\n
                if text.startswith(b"\x01"):
                    head, _, text = text[1:].partition(b"\n")
                    if head in (b"de", b"en"):
                        language = head.decode()
                for wav in tts.stream(text.decode("utf-8", "replace"), language=language, seed=SEED):
                    conn.sendall((wav.clip(-1.0, 1.0) * 32767).astype("<i2").tobytes())
            except OSError as e:   # the client is gone (stopped), or the voice cannot be read
                if not isinstance(e, (BrokenPipeError, ConnectionResetError)):
                    print("speak-server: %s" % e, file=sys.stderr, flush=True)
            except Exception as e:   # one text that fails must not end the server
                print("speak-server: %r" % e, file=sys.stderr, flush=True)

    def remove_socket():
        try:
            if os.stat(path).st_ino == mine:   # a newer server may have taken the path
                os.unlink(path)
        except OSError:
            pass

    srv.settimeout(IDLE_SECONDS)
    try:
        while True:
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                break
            answer(conn)
        remove_socket()   # from now on a new text starts a new server
        srv.setblocking(False)
        while True:       # the ones that connected before the socket went still get their text read
            try:
                conn, _ = srv.accept()
            except BlockingIOError:
                break
            answer(conn)
    finally:
        remove_socket()

if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit("usage: speak-server.py SOCKET MODEL_DIR VOICE_WAV [LOCK_FD]")
    serve(*sys.argv[1:])
