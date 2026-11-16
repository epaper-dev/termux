package com.termux.app.assist;

import android.content.Intent;
import android.os.RemoteException;
import android.speech.RecognitionService;
import android.speech.SpeechRecognizer;

/**
 * Android wants a recognition service in the metadata of every voice interaction service, or it refuses to list the
 * app as a digital assistant. Termux recognises no speech here (Claude Code does the dictation): every request
 * is answered with an error. The service has no intent filter, so it does not show up as a speech recognizer of its own.
 */
public class PttRecognitionService extends RecognitionService {

    @Override
    protected void onStartListening(Intent recognizerIntent, Callback listener) {
        try {
            listener.error(SpeechRecognizer.ERROR_CLIENT);
        } catch (RemoteException ignored) {
            // the caller is gone
        }
    }

    @Override
    protected void onStopListening(Callback listener) {
    }

    @Override
    protected void onCancel(Callback listener) {
    }
}
