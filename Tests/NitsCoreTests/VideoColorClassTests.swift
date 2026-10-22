import CoreVideo
import Testing

@testable import NitsCore

/// One classification feeds both the media info's labels and the shader's uniforms.
@Suite("Video colour classes")
struct VideoColorClassTests {
    @Test("Standard-definition primaries are labelled BT.601, not BT.2020")
    func labelsPrimaries() {
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_SMPTE_C).label == "BT.601")
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_EBU_3213).label == "BT.601")
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_ITU_R_709_2).label == "BT.709")
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_P3_D65).label == "DCI-P3")
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_ITU_R_2020).label == "BT.2020")
    }

    @Test("SDR transfer functions other than BT.709 are labelled as themselves, not PQ")
    func labelsTransferFunctions() {
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_sRGB).label == "sRGB")
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_SMPTE_240M_1995).label == "SMPTE 240M")
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_UseGamma).label == "BT.709 / SDR")
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ).label == "PQ (ST 2084)")
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_ITU_R_2100_HLG).label == "HLG")
    }

    @Test("The shader gets the indices it always did")
    func shaderIndices() {
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_ITU_R_2020).shaderIndex == 0)
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_ITU_R_709_2).shaderIndex == 1)
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_DCI_P3).shaderIndex == 2)
        #expect(ColorPrimariesClass(kCVImageBufferColorPrimaries_SMPTE_C).shaderIndex == 0)
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ).shaderIndex == 0)
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_ITU_R_2100_HLG).shaderIndex == 1)
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_ITU_R_709_2).shaderIndex == 2)
        #expect(TransferFunctionClass(kCVImageBufferTransferFunction_sRGB).shaderIndex == 0)
    }
}
