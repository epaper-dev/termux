package com.termux.app.assist;

import android.service.voice.VoiceInteractionService;

/**
 * Makes Termux selectable as the digital assistant of the phone (Settings, Apps, Default apps, Digital assistant
 * app). The assistant is what a long press on Home starts; the work is done by {@link PttVoiceInteractionSession}.
 */
public class PttVoiceInteractionService extends VoiceInteractionService {
}
