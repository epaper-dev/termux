package com.termux.app.assist;

import android.os.Bundle;
import android.service.voice.VoiceInteractionSession;
import android.service.voice.VoiceInteractionSessionService;

/** Creates the session that the system opens when the user invokes the assistant. */
public class PttVoiceInteractionSessionService extends VoiceInteractionSessionService {

    @Override
    public VoiceInteractionSession onNewSession(Bundle args) {
        return new PttVoiceInteractionSession(this);
    }
}
