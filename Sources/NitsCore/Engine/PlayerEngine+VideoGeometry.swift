import Foundation

extension PlayerEngine {
    /// Forces a display aspect ratio on the picture (`nil`: the stream's) and saves it for the file.
    public func setVideoAspectRatio(_ ratio: RationalAspectRatio?) {
        let ratio = ratio?.isValid == true ? ratio : nil
        guard ratio != videoGeometry.aspectRatio else { return }
        videoGeometry.aspectRatio = ratio
        AppLog.info(.video, "Aspect ratio override: \(ratio?.displayName ?? "none")")
        saveCurrentPlaybackProgress()
    }

    /// Crops the picture to a display aspect ratio (`nil`: no crop) and saves it for the file.
    public func setVideoCrop(_ ratio: RationalAspectRatio?) {
        let ratio = ratio?.isValid == true ? ratio : nil
        guard ratio != videoGeometry.crop else { return }
        videoGeometry.crop = ratio
        AppLog.info(.video, "Crop: \(ratio?.displayName ?? "none")")
        saveCurrentPlaybackProgress()
    }

    /// Steps through the aspect ratio presets, the stream's own ratio first.
    public func cycleVideoAspectRatio() {
        setVideoAspectRatio(RationalAspectRatio.nextDisplayPreset(after: videoGeometry.aspectRatio))
    }

    /// Kept across files for the session, like `renderMode`.
    public func setVideoScaling(_ scaling: VideoScaling) {
        videoGeometry.scaling = scaling
    }

    public func cycleVideoScaling() {
        setVideoScaling(videoGeometry.scaling.next)
    }

    /// Zooms by `steps` of `VideoGeometrySettings.zoomStepFactor`.
    public func stepVideoZoom(by steps: Int) {
        videoGeometry = videoGeometry.zoomed(bySteps: steps)
    }

    /// Sets the zoom, clamped to `VideoGeometrySettings.zoomRange` (pinch).
    public func setVideoZoom(_ zoom: Double) {
        guard zoom.isFinite else { return }
        let range = VideoGeometrySettings.zoomRange
        videoGeometry.zoom = min(max(zoom, range.lowerBound), range.upperBound)
    }

    public func resetVideoZoom() {
        videoGeometry.zoom = 1.0
        videoGeometry.pan = .zero
    }

    /// Moves a picture larger than the view; see `VideoGeometrySettings.pan`.
    public func setVideoPan(_ pan: CGPoint) {
        guard pan.x.isFinite, pan.y.isFinite else { return }
        videoGeometry.pan = CGPoint(x: min(max(pan.x, -1), 1), y: min(max(pan.y, -1), 1))
    }

    /// Takes the saved aspect override and crop of the file being loaded; zoom and pan start over, the scaling mode
    /// stays.
    func restoreVideoGeometry(from preferences: PlaybackPreferences?) {
        var geometry = videoGeometry
        geometry.aspectRatio = preferences?.videoAspectRatio.flatMap { $0.isValid ? $0 : nil }
        geometry.crop = preferences?.videoCrop.flatMap { $0.isValid ? $0 : nil }
        geometry.zoom = 1.0
        geometry.pan = .zero
        videoGeometry = geometry
        if geometry.aspectRatio != nil || geometry.crop != nil {
            AppLog.info(
                .video,
                "Restored picture geometry from saved history: aspect \(geometry.aspectRatio?.displayName ?? "source"), "
                    + "crop \(geometry.crop?.displayName ?? "none")")
        }
    }
}
