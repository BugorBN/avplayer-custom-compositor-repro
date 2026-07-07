// VideoPlayerApp.swift

import SwiftUI

@main
struct VideoPlayerApp: App {
	var body: some Scene {
		WindowGroup {
			// Repro of the composition + custom-compositor playback failure.
			CompositorReproView()
		}
	}
}
