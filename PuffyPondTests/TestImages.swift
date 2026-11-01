import CoreGraphics

/// Small CGImage helpers shared by the Magic tests.
func solidImage(gray: CGFloat, _ w: Int, _ h: Int, redLineAtY: Int? = nil) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if let y = redLineAtY {
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 40, y: y - 4, width: w - 80, height: 8))
    }
    return ctx.makeImage()!
}

/// Gray value (0…255) of one pixel, top-left origin.
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
    var value: UInt8 = 0
    let ctx = CGContext(data: &value, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return value
}
