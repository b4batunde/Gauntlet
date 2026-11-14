import AppKit
import Metal
import SceneKit

// Renders the Gauntlet showcase film.
//
//   swift run -c release promo                         full film -> showcase/Gauntlet-TeamGestures.mp4
//   swift run promo --stills 8,21,33 --dir /tmp/out    single frames as PNG, for checking the look
//   swift run promo --from 27 --to 47 --out part.mp4   render only part of the timeline
//   options: --fps 60  --size 1920x1080  --assets showcase/assets  --no-audio

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.indices.contains(i + 1) else { return nil }
    return arguments[i + 1]
}

let sizeParts = (option("--size") ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
let width = sizeParts.count == 2 ? sizeParts[0] : 1920
let height = sizeParts.count == 2 ? sizeParts[1] : 1080
let fps = Double(option("--fps") ?? "60") ?? 60
let assets = option("--assets") ?? "showcase/assets"

guard let device = MTLCreateSystemDefaultDevice() else {
    FileHandle.standardError.write(Data("promo: no Metal device available\n".utf8))
    exit(1)
}
let studio = Studio()
let director = Director(studio: studio, assets: assets)
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = studio.scene
renderer.pointOfView = studio.cameraNode
renderer.autoenablesDefaultLighting = false

// One BGRA canvas reused for every frame: the 3D render goes in first, titles on top.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                             space: space, bitmapInfo: bitmapInfo) else { exit(1) }

func composeFrame(at t: Double) {
    director.apply(t)
    let frame = renderer.snapshot(atTime: t, with: CGSize(width: width, height: height), antialiasingMode: .multisampling4X)
    let rect = CGRect(x: 0, y: 0, width: width, height: height)
    canvas.setFillColor(NSColor.black.cgColor)
    canvas.fill(rect)
    if let cg = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) { canvas.draw(cg, in: rect) }
    canvas.saveGState()
    canvas.translateBy(x: 0, y: CGFloat(height))
    canvas.scaleBy(x: 1, y: -1)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: true)
    director.overlay(canvas, t: t, width: CGFloat(width), height: CGFloat(height))
    NSGraphicsContext.current = previous
    canvas.restoreGState()
}

// MARK: Soundtrack only

if let path = option("--audio-only") {
    Soundtrack.write(to: path, from: 0, to: Director.duration)
    print("wrote \(path)")
    exit(0)
}

// MARK: Stills

if let list = option("--stills") {
    let directory = option("--dir") ?? "showcase/stills"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for value in list.split(separator: ",").compactMap({ Double($0) }) {
        autoreleasepool {
            composeFrame(at: value)
            if let image = canvas.makeImage(),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                let path = "\(directory)/frame-\(String(format: "%05.2f", value)).png"
                try? png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            }
        }
    }
    exit(0)
}

// MARK: Film

let start = Double(option("--from") ?? "0") ?? 0
let end = min(Director.duration, Double(option("--to") ?? "\(Director.duration)") ?? Director.duration)
let output = option("--out") ?? "showcase/Gauntlet-TeamGestures.mp4"
try? FileManager.default.createDirectory(atPath: (output as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    FileHandle.standardError.write(Data("promo: ffmpeg not found (brew install ffmpeg)\n".utf8))
    exit(1)
}

var audioPath: String?
if !arguments.contains("--no-audio") {
    let path = NSTemporaryDirectory() + "gauntlet-soundtrack-\(ProcessInfo.processInfo.processIdentifier).wav"
    Soundtrack.write(to: path, from: start, to: end)
    audioPath = path
    print("soundtrack synthesised")
}

let encoder = Process()
encoder.executableURL = URL(fileURLWithPath: ffmpeg)
var encoderArguments = ["-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)",
                        "-r", "\(fps)", "-i", "-"]
if let audioPath { encoderArguments += ["-i", audioPath] }
encoderArguments += ["-c:v", "libx264", "-preset", "slow", "-crf", "15", "-pix_fmt", "yuv420p",
                     "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
if audioPath != nil { encoderArguments += ["-c:a", "aac", "-b:a", "256k", "-shortest"] }
encoderArguments += ["-movflags", "+faststart", output]
encoder.arguments = encoderArguments
let pipe = Pipe()
encoder.standardInput = pipe
do { try encoder.run() } catch {
    FileHandle.standardError.write(Data("promo: could not start ffmpeg: \(error.localizedDescription)\n".utf8))
    exit(1)
}

let frames = Int(((end - start) * fps).rounded())
let began = Date()
for index in 0..<frames {
    autoreleasepool {
        composeFrame(at: start + Double(index) / fps)
        if let data = canvas.data {
            pipe.fileHandleForWriting.write(Data(bytesNoCopy: data, count: width * height * 4, deallocator: .none))
        }
    }
    if index % 120 == 0 {
        let elapsed = Date().timeIntervalSince(began)
        let rate = Double(index + 1) / max(0.001, elapsed)
        print(String(format: "frame %d/%d  (%.1f fps, about %.0f s left)", index, frames, rate, Double(frames - index) / rate))
        fflush(stdout)
    }
}
try? pipe.fileHandleForWriting.close()
encoder.waitUntilExit()
if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
print(encoder.terminationStatus == 0 ? "wrote \(output)" : "ffmpeg failed with status \(encoder.terminationStatus)")
exit(encoder.terminationStatus)
