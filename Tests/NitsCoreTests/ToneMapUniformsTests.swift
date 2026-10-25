import Foundation
import Metal
import Testing

@testable import NitsCore

@Suite("ToneMapUniforms & Renderer Concurrency Tests")
struct ToneMapUniformsTests {
    @Test("Default uniforms target the reference white")
    func testDefaultUniforms() {
        let uniforms = ToneMapUniforms()
        #expect(uniforms.targetNits == ToneMapController.referenceWhiteNits)
        #expect(uniforms.outputSharpness == 0.5)
        #expect(uniforms.outputExposure == 1.0)
    }

    @Test("Tone mapping shaders link across .metal files into a render pipeline")
    func testToneMapPipelineLinks() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let library = try device.makeDefaultLibrary(bundle: .module)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "hdrVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "hdrToneMapFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgr10a2Unorm
        // Fails if mpvBT2390 (BT2390ToneMapping.metal), fitToDisplayP3 (DisplayGamutFit.metal) or the PQ helpers
        // they use don't resolve.
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @Test("ToneMapUniforms mutation via MetalVideoRenderer is thread-safe")
    func testRendererUniformsThreadSafety() async {
        guard let renderer = MetalVideoRenderer() else { return }

        // Concurrently mutate uniforms across multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let sharpness = Float(i) / 100.0
                    renderer.updateUniforms { u in
                        u.outputSharpness = sharpness
                        u.outputExposure = 1.0 + Float(i) * 0.01
                    }
                    _ = renderer.uniforms.outputSharpness
                }
            }
        }

        #expect(renderer.uniforms.outputSharpness >= 0.0 && renderer.uniforms.outputSharpness <= 1.0)
    }
}
