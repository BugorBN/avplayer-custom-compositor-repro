// CompositorRepro.swift
//
// Minimal, self-contained reproduction of an AVPlayer playback failure that occurs when an
// AVMutableComposition-backed AVPlayerItem is given an AVMutableVideoComposition driven by a
// custom AVVideoCompositing (customVideoCompositorClass).
//
// Observed on iOS Simulator: the AVPlayerItem transitions to .failed with
//   AVFoundationErrorDomain -11800 (AVErrorUnknown),
//   underlying NSOSStatusErrorDomain -12784,
// and the console logs:
//   FPSupport_CreateDefaultCoordinationIdentifierForPlaybackItem signalled
//   err=-12927 (kFigPlayerError_IncompatibleAsset) (not a URL asset)
//
// Playing the same composition WITHOUT attaching the custom video composition works fine.
// The custom compositor here is a trivial pass-through (source frame -> finish), so no custom
// rendering, Core Image, threading, or model inference is involved — the failure is purely about
// having a custom video compositor attached to a composition-backed item.

import AVFoundation
import CoreVideo
import SwiftUI
import UIKit

// MARK: - Custom video compositor (trivial pass-through)

final class ReproCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
	let sourcePixelBufferAttributes: [String: any Sendable]? = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferOpenGLESCompatibilityKey as String: true,
		kCVPixelBufferMetalCompatibilityKey as String: true,
	]

	let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
		kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		kCVPixelBufferOpenGLESCompatibilityKey as String: true,
		kCVPixelBufferMetalCompatibilityKey as String: true,
	]

	func renderContextChanged(_: AVVideoCompositionRenderContext) {}

	func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		// Pass the source frame straight through to the composed output.
		guard let trackID = request.sourceTrackIDs.first,
		      let sourcePixelBuffer = request.sourceFrame(byTrackID: trackID.int32Value)
		else {
			request.finish(with: NSError(domain: "ReproCompositor", code: -1))
			return
		}
		request.finish(withComposedVideoFrame: sourcePixelBuffer)
	}

	func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Model

@MainActor
@Observable
final class CompositorReproModel {
	var player: AVPlayer?
	var statusText = "Tap “Reproduce” to build a composition-backed player item with a custom video compositor."

	private var statusObservation: NSKeyValueObservation?

	func reproduce() {
		build()
	}

	private func build() {
		statusObservation?.invalidate()
		player = nil
		statusText = "Building composition + custom video composition…"

		guard let url = Bundle.main.url(forResource: "IMG_8366", withExtension: "mov") else {
			statusText = "❌ IMG_8366.mov not found in bundle"
			return
		}

		let asset = AVURLAsset(url: url)

		do {
			// Synchronous asset access (deprecated but fine for a local-file repro) keeps everything
			// on the main actor and avoids obscuring the repro with async loading machinery.
			guard let sourceTrack = asset.tracks(withMediaType: .video).first else {
				statusText = "❌ asset has no video track"
				return
			}
			let duration = asset.duration
			let renderSize = sourceTrack.naturalSize

			// Composition-backed item (NOT a URL asset) — same as the real app.
			let composition = AVMutableComposition()
			guard let compositionTrack = composition.addMutableTrack(
				withMediaType: .video,
				preferredTrackID: kCMPersistentTrackID_Invalid
			) else {
				statusText = "❌ could not add composition track"
				return
			}
			try compositionTrack.insertTimeRange(
				CMTimeRange(start: .zero, duration: duration),
				of: sourceTrack,
				at: .zero
			)

			let playerItem = AVPlayerItem(asset: composition)

			// Attach a custom video composition. THIS is what triggers the failure.
			let videoComposition = AVMutableVideoComposition()
			videoComposition.frameDuration = CMTime(value: 1, timescale: 25)
			videoComposition.renderSize = renderSize
			videoComposition.customVideoCompositorClass = ReproCompositor.self

			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
			let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionTrack)
			instruction.layerInstructions = [layerInstruction]
			videoComposition.instructions = [instruction]

			playerItem.videoComposition = videoComposition

			statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
				let status = item.status
				let error = item.error as NSError?
				Task { @MainActor [weak self] in
					switch status {
					case .failed:
						var lines = ["❌ AVPlayerItem.status == .failed"]
						if let error {
							lines.append("domain=\(error.domain) code=\(error.code)")
							lines.append(error.localizedDescription)
							if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
								lines.append("underlying: domain=\(underlying.domain) code=\(underlying.code)")
							}
						}
						self?.statusText = lines.joined(separator: "\n")
						print(lines.joined(separator: " | "))
					case .readyToPlay:
						self?.statusText = "✅ AVPlayerItem.status == .readyToPlay (playing)"
					default:
						self?.statusText = "AVPlayerItem.status == .unknown"
					}
				}
			}

			let player = AVPlayer(playerItem: playerItem)
			self.player = player
			player.play()
			statusText = "Player created — waiting for status…"
		} catch {
			statusText = "❌ setup threw: \(error)"
		}
	}
}

// MARK: - View

struct CompositorReproView: View {
	@State private var model = CompositorReproModel()

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let player = model.player {
				ReproPlayerLayerView(player: player)
					.ignoresSafeArea()
			}

			VStack(spacing: 16) {
				Text(model.statusText)
					.font(.system(.footnote, design: .monospaced))
					.foregroundStyle(.white)
					.multilineTextAlignment(.center)
					.padding()
					.background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
					.padding(.horizontal)

				Spacer()

				Button("Reproduce") {
					model.reproduce()
				}
				.font(.headline)
				.foregroundStyle(.black)
				.padding(.horizontal, 28)
				.padding(.vertical, 14)
				.background(.white, in: Capsule())
				.padding(.bottom, 44)
			}
			.padding(.top, 60)
		}
	}
}

// MARK: - AVPlayerLayer host

struct ReproPlayerLayerView: UIViewRepresentable {
	let player: AVPlayer

	func makeUIView(context _: Context) -> ReproPlayerContainerView {
		let view = ReproPlayerContainerView()
		view.playerLayer.player = player
		view.playerLayer.videoGravity = .resizeAspect
		return view
	}

	func updateUIView(_ uiView: ReproPlayerContainerView, context _: Context) {
		uiView.playerLayer.player = player
	}
}

final class ReproPlayerContainerView: UIView {
	override static var layerClass: AnyClass { AVPlayerLayer.self }
	var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

#Preview {
	CompositorReproView()
}
