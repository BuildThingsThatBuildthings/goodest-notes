import CryptoKit
import Foundation
import Network
import PencilKit
import XCTest
@testable import Blockbook

final class CanvasTests: XCTestCase {
    @MainActor func testDuetAddsSecondWriterWithoutReplacingPencilInk() throws {
        let canvas=CloudInkCanvas()
        let pencil=inkStroke(at:CGPoint(x:10,y:20),color:.blue)
        let finger=inkStroke(at:CGPoint(x:50,y:60),color:.red)
        canvas.drawing=PKDrawing(strokes:[pencil])
        Instrument.duet.configureInk(canvas,color:.blue,width:3)
        XCTAssertEqual(canvas.drawingPolicy,.pencilOnly)
        canvas.finishFinger(finger,preview:CAShapeLayer())
        let saved=try PKDrawing(data:canvas.drawing.dataRepresentation())
        XCTAssertEqual(saved.strokes.count,2)
        XCTAssertEqual(saved.strokes.first?.path.first?.location,pencil.path.first?.location)
        XCTAssertEqual(saved.strokes.last?.path.first?.location,finger.path.first?.location)
        Instrument.pen.configureInk(canvas,color:.blue,width:3)
        XCTAssertEqual(canvas.drawingPolicy,.anyInput)
    }

    func testPolishingKeepsOriginalInkAndStrokeEndpoints() throws {
        let points = [CGPoint(x:0,y:0),CGPoint(x:5,y:2),CGPoint(x:10,y:0)].enumerated().map { i, p in
            PKStrokePoint(location:p,timeOffset:Double(i)/60,size:CGSize(width:2,height:2),
                          opacity:1,force:0.6,azimuth:0,altitude:1)
        }
        let stroke = PKStroke(ink:PKInk(.pen,color:.blue),path:PKStrokePath(controlPoints:points,creationDate:Date()))
        let polished = try XCTUnwrap(HandwritingSmoothing.drawing([stroke],strength:1).strokes.first)
        XCTAssertEqual(polished.path[0].location,stroke.path[0].location)
        XCTAssertEqual(polished.path[2].location,stroke.path[2].location)
        XCTAssertLessThan(polished.path[1].location.y,stroke.path[1].location.y)
        XCTAssertEqual(stroke.path[1].location,points[1].location)
        XCTAssertEqual(polished.path[1].force,stroke.path[1].force)
    }

    func testGlowInkSurvivesPencilKitSaveAndAddsAHalo() throws {
        let glow = inkStroke(at: CGPoint(x: 40, y: 40), color: GlowInk.color(.systemPurple))
        let pen = inkStroke(at: CGPoint(x: 160, y: 80))
        let saved = try PKDrawing(data: PKDrawing(strokes: [glow, pen]).dataRepresentation())
        let highlighted = GlowInk.strokes(in: saved)
        XCTAssertEqual(highlighted.count, 1)
        let rect = CGRect(x: 0, y: 0, width: 120, height: 90)
        let plain = SheetRenderer.image(rect: rect) { _ in }.pngData()
        let rendered = SheetRenderer.image(rect: rect) { GlowInk.paint(highlighted, in: $0, visible: rect) }.pngData()
        XCTAssertNotEqual(plain, rendered)
        XCTAssertTrue(GlowInk.strokes(in: PKDrawing(strokes: [pen])).isEmpty)
    }

    func testHandwrittenContextSelectsNearbyStrokesAndFollowsTheirBounds() throws {
        let a = inkStroke(at: CGPoint(x: 40, y: 40))
        let b = inkStroke(at: CGPoint(x: 58, y: 41))
        let distant = inkStroke(at: CGPoint(x: 140, y: 40))
        let secondLine = inkStroke(at: CGPoint(x: 42, y: 90))
        let ink = PKDrawing(strokes: [a, b, distant, secondLine])
        let item = try XCTUnwrap(InkContextAnchor.item(at: CGPoint(x: 45, y: 43), in: ink, tolerance: 5))
        let anchor = try XCTUnwrap(item.inkAnchor)
        XCTAssertEqual(Set(anchor.strokes), Set([InkContextAnchor.key(a), InkContextAnchor.key(b)]))
        let moved = Dictionary(uniqueKeysWithValues: [a, b].map { (InkContextAnchor.key($0), $0.renderBounds.offsetBy(dx: 100, dy: -20)) })
        let frame = try XCTUnwrap(anchor.updatedFrame(using: moved))
        XCTAssertEqual(frame.midX, item.frame.midX + 100, accuracy: 0.01)
        XCTAssertEqual(frame.midY, item.frame.midY - 20, accuracy: 0.01)
        XCTAssertNil(anchor.updatedFrame(using: [:]))
    }

    func testContextEditsKeepConcurrentLayoutAndUnrelatedAttachments() throws {
        let original = CanvasItem(kind: .text, title: "Workshop", frame: CGRect(x: 30, y: 40, width: 200, height: 75))
        var live = original
        live.frame.origin.x = 600
        live.audioNote = CanvasAsset(filename: "Audio note.m4a", type: "public.mpeg-4-audio")
        var edit = original
        edit.markdown = "Bring cards and markers."
        edit.link = "https://example.com/workshop"
        let merged = try live.mergingContext(from: original, changes: edit)
        XCTAssertEqual(merged.frame, live.frame)
        XCTAssertEqual(merged.audioNote, live.audioNote)
        XCTAssertEqual(merged.markdown, edit.markdown)
        XCTAssertEqual(merged.link, edit.link)
        live.markdown = "Someone saved something newer."
        XCTAssertThrowsError(try live.mergingContext(from: original, changes: edit))
    }

    private func inkStroke(at point: CGPoint, color: UIColor = .systemPurple) -> PKStroke {
        let points = (0..<3).map { i in
            PKStrokePoint(location: CGPoint(x: point.x + CGFloat(i) * 5, y: point.y + CGFloat(i) * 3),
                          timeOffset: Double(i) / 15, size: CGSize(width: 5, height: 5), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    func testWritingMagnifierKeepsFinitePagesInBoundsAndWideBoardsReachable() {
        let size = CGSize(width: 620, height: 155)
        let page = CGSize(width: 768, height: 1024)
        let bounded = WritingMagnifier.camera(center: CGPoint(x: -100, y: 1_600), size: size, scale: 2, page: page)
        XCTAssertEqual(bounded.visibleWorld.minX, 0, accuracy: 0.01)
        XCTAssertEqual(bounded.visibleWorld.maxY, page.height, accuracy: 0.01)
        let target = CGPoint(x: -220_000, y: 31_000)
        let infinite = WritingMagnifier.camera(center: target, size: size, scale: 3, page: nil)
        XCTAssertEqual(infinite.center, target)
        XCTAssertEqual(infinite.scale, 3)
        XCTAssertEqual(infinite.world(CGPoint(x: 310, y: 77.5)), target)
        XCTAssertLessThanOrEqual(BoardCamera.editingScale, 0.08)
    }

    func testConnectionCodeCarriesTheWholePrivateEndpoint() {
        let key = Data(repeating: 19, count: 32).base64EncodedString()
        let code = AgentPairingCode(address: "192.168.0.20", port: 49155, key: key)
        XCTAssertEqual(AgentPairingCode(code.value + "\n"), code)
        XCTAssertNil(AgentPairingCode("BB1:8.8.8.8:49155:" + key))
        XCTAssertNil(AgentPairingCode("BB1:192.168.0.20:0:" + key))
        XCTAssertNil(AgentPairingCode("BB1:192.168.0.20:49155:wrong"))
    }

    func testOldLibraryDecodesAndProjectDeletionPreservesMembers() throws {
        let old = try JSONDecoder().decode(Library.self, from: Data(#"{"version":1,"papers":[],"workflows":[],"blocks":[]}"#.utf8))
        XCTAssertTrue(old.allProjects.isEmpty)
        var library = old
        let paper = Paper(title: "Reference", kind: .whiteboard, pages: [SheetPage()])
        let project = Project(title: "Class")
        library.papers.append(paper)
        library.addProject(project)
        library.assign(.init(.paper, paper.id), to: project.id, included: true)
        library.assign(.init(.paper, paper.id), to: project.id, included: true)
        let restored = try JSONDecoder().decode(Library.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(restored.allProjects.first?.entries, [.init(.paper, paper.id)])
        library.projects?.removeAll { $0.id == project.id }
        XCTAssertEqual(library.papers, [paper])
    }

    func testDeletingABaseRepairsVariationsAndOnlyRemovesItsPlacements() {
        var base = Block(title: "Base")
        base[.outcome] = "Outcome"
        base.context = "**Context**"
        var variation = Block(title: "Remote", parentID: base.id)
        variation[.tools] = "Remote tools"
        let grandchild = Block(title: "Remote later", parentID: variation.id)
        let workflow = Workflow(title: "Workshop", steps: [Placement(blockID: base.id), Placement(blockID: variation.id)])
        let project = Project(title: "Class", entries: [.init(.block, base.id), .init(.block, variation.id)])
        var library = Library(workflows: [workflow], blocks: [base, variation, grandchild], projects: [project])
        library.delete(.init(.block, base.id))
        XCTAssertEqual(library.workflows[0].steps.map(\.blockID), [variation.id])
        XCTAssertEqual(library.projects?[0].entries.map(\.id), [variation.id])
        let saved = library.blocks.first { $0.id == variation.id }
        XCTAssertNil(saved?.parentID)
        XCTAssertEqual(saved?[.outcome], "Outcome")
        XCTAssertEqual(saved?.context, "**Context**")
        XCTAssertEqual(library.resolved(grandchild)[.tools], "Remote tools")
    }

    @MainActor func testInfiniteWorldCoordinatesKeepInkStableThroughRecenter() throws {
        let point = CGPoint(x: -45_000, y: 22_000)
        let drawingPoint = PKStrokePoint(location: point, timeOffset: 0, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: 1)
        let path = PKStrokePath(controlPoints: [drawingPoint], creationDate: .now)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        let page = SheetPage(size: CGSize(width: 2400, height: 1800))
        let surface = BoardSurface(page: page, drawing: drawing)
        surface.frame = CGRect(x: 0, y: 0, width: 600, height: 700)
        surface.layoutIfNeeded()
        var emitted = 0
        surface.changed = { _ in emitted += 1 }
        for target in [point, CGPoint(x: 180_000, y: -120_000), point] {
            surface.reveal(target)
            XCTAssertEqual(surface.worldCenter.x, target.x, accuracy: 1)
            XCTAssertEqual(surface.worldCenter.y, target.y, accuracy: 1)
        }
        XCTAssertEqual(emitted, 0)
        XCTAssertEqual(surface.ink.drawing.strokes.count, 1)
        XCTAssertEqual(surface.ink.bounds.size, CGSize(width: 600, height: 700))
        XCTAssertEqual(surface.ink.drawing.bounds.midX, 300, accuracy: 2)
    }

    @MainActor func testWideBoardFitsBothEndsAndPansWithoutAWindowEdge() {
        let left = CanvasItem(kind: .note, title: "West", frame: CGRect(x: -220_000, y: -75, width: 280, height: 170))
        let right = CanvasItem(kind: .note, title: "East", frame: CGRect(x: 230_000, y: -75, width: 280, height: 170))
        let page = SheetPage(canvas: CanvasContent(items: [left, right], connections: [CanvasConnection(from: left.id, to: right.id)]))
        let surface = BoardSurface(page: page, drawing: PKDrawing())
        surface.frame = CGRect(x: 0, y: 0, width: 730, height: 520)
        surface.layoutIfNeeded()
        XCTAssertTrue(surface.camera.visibleWorld.contains(left.frame))
        XCTAssertTrue(surface.camera.visibleWorld.contains(right.frame))
        XCTAssertLessThan(surface.camera.scale, 0.01)

        surface.reveal(.zero)
        let dx: CGFloat = -630
        let scale = surface.camera.scale
        for _ in 0..<32 { surface.moveViewport(by: CGPoint(x: dx, y: 0)) }
        XCTAssertEqual(surface.worldCenter.x, -32 * dx / scale, accuracy: 1)
        let xBeforeScroll = surface.worldCenter.x
        surface.setContentOffset(CGPoint(x: surface.contentOffset.x + 380, y: surface.contentOffset.y), animated: false)
        XCTAssertEqual(surface.worldCenter.x, xBeforeScroll + 380 / scale, accuracy: 1)
        let offset = surface.contentOffset
        var fling = CGPoint(x: offset.x + 8_000, y: offset.y - 8_000)
        surface.scrollViewWillEndDragging(surface, withVelocity: CGPoint(x: 20, y: -20), targetContentOffset: &fling)
        XCTAssertEqual(fling.x - offset.x, 146, accuracy: 0.01)
        XCTAssertEqual(fling.y - offset.y, -104, accuracy: 0.01)
        let centerBeforeRecentering = surface.worldCenter
        surface.scrollViewDidEndDragging(surface, willDecelerate: false)
        XCTAssertEqual(surface.worldCenter, centerBeforeRecentering)
        let before = surface.worldCenter
        surface.frame.size = CGSize(width: 420, height: 650)
        surface.layoutIfNeeded()
        XCTAssertEqual(surface.worldCenter, before)
        XCTAssertEqual(surface.ink.bounds.size, CGSize(width: 420, height: 650))
        surface.fit()
        XCTAssertTrue(surface.camera.visibleWorld.contains(left.frame.union(right.frame)))
        let clipped = CanvasSegment(start: CGPoint(x: -450_000, y: 82), end: CGPoint(x: 630_000, y: 82)).clipped(to: CGRect(x: 0, y: 0, width: 420, height: 650))
        XCTAssertEqual(clipped?.start.x ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(clipped?.end.x ?? -1, 420, accuracy: 0.01)
    }

    @MainActor func testViewportInkEditsPreserveTheRestOfTheBoard() throws {
        func stroke(x: CGFloat, y: CGFloat, seed: UInt32) -> PKStroke {
            let points = [x, x + 24].enumerated().map { i, point in
                PKStrokePoint(location: CGPoint(x: point, y: y), timeOffset: Double(i) / 10, size: CGSize(width: 6, height: 6), opacity: 1, force: 1, azimuth: 0, altitude: 1)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now), randomSeed: seed)
        }
        let hidden = stroke(x: -95_000, y: 20_000, seed: 51)
        let visible = stroke(x: 102_000, y: 30_000, seed: 52)
        let drawing = PKDrawing(strokes: [hidden, visible])
        var camera = BoardCamera(center: CGPoint(x: 102_000, y: 30_000), size: CGSize(width: 650, height: 500))
        camera.zoom(to: 1.25, holding: camera.center, at: CGPoint(x: 325, y: 250))
        var window = BoardInkWindow(drawing: drawing, camera: camera)
        XCTAssertEqual(window.projectedDrawing.strokes.map(\.randomSeed), [52])
        let local = try XCTUnwrap(window.projectedDrawing.strokes.first)
        let added = stroke(x: 360, y: 270, seed: 53)
        let first = window.merge(PKDrawing(strokes: [local, added]))
        XCTAssertEqual(first.strokes.map(\.randomSeed), [51, 52, 53])
        XCTAssertEqual(first.strokes[1].renderBounds, visible.renderBounds)
        let second = window.merge(PKDrawing(strokes: [added]))
        XCTAssertEqual(second.strokes.map(\.randomSeed), [51, 53])
        XCTAssertEqual(second.strokes[0].renderBounds, hidden.renderBounds)
        XCTAssertEqual(second.strokes[1].renderBounds.midX, camera.world(CGPoint(x: 372, y: 270)).x, accuracy: 2)
    }

    @MainActor func testPortableMarkdownIncludesMediaInkNotesAndDirectedConnections() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let studio = Studio(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = folder.appendingPathComponent("diagram.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { output in UIColor.systemBlue.setFill(); output.fill(CGRect(x: 0, y: 0, width: 40, height: 40)) }
        try XCTUnwrap(image.pngData()).write(to: photo)
        let asset = try await studio.importAsset(photo)
        let imageItem = CanvasItem(kind: .image, title: "Diagram", markdown: "**Evidence**", asset: asset, frame: CGRect(x: -300, y: 300, width: 320, height: 240))
        let linked = Paper(title: "Reference", kind: .notebook, pages: [SheetPage()])
        let link = CanvasItem(kind: .link, title: "Read first", link: LibraryReference(.paper, linked.id).link, frame: CGRect(x: 450, y: 800, width: 240, height: 100))
        let edge = CanvasConnection(from: imageItem.id, to: link.id, label: "See documentation")
        let p = SheetPage(typed: "# Research notes", inkText: "Previously recognized", canvas: CanvasContent(items: [imageItem, link], connections: [edge]))
        let board = Paper(title: "Research", kind: .whiteboard, pages: [p])
        let project = Project(title: "Class", markdown: "## Project context", entries: [.init(.paper, board.id), .init(.paper, linked.id)])
        XCTAssertTrue(studio.change { $0.papers = [board, linked]; $0.addProject(project) })
        let inkPoint = PKStrokePoint(location: CGPoint(x: -75, y: 900), timeOffset: 0, size: CGSize(width: 12, height: 12), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [inkPoint], creationDate: .now))
        try PKDrawing(strokes: [stroke]).dataRepresentation().write(to: studio.url(p.id, "drawing"))
        let bundle = try await WorkspaceMarkdown(studio: studio).writeProject(project)
        let body = try String(contentsOf: bundle.appendingPathComponent("research-\(board.id.uuidString.lowercased()).md"), encoding: .utf8)
        XCTAssertTrue(body.contains("# Research notes"))
        XCTAssertTrue(body.contains("Previously recognized"))
        XCTAssertTrue(body.contains("x -300.0"))
        XCTAssertTrue(body.contains("**Evidence**"))
        XCTAssertTrue(body.contains("See documentation"))
        XCTAssertTrue(body.contains("reference-\(linked.id.uuidString.lowercased()).md"))
        XCTAssertTrue(body.contains("Original PencilKit ink"))
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("assets/\(asset.storageName)")), try Data(contentsOf: photo))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("index.md").path))
        XCTAssertEqual(Studio(folder: folder).paper(board.id)?.pages.first?.canvas?.connections, [edge])
    }

    @MainActor func testAgentBatchIsAtomicScopedAndSafeToReplay() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let studio = Studio(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = Project(title: "Shared")
        let outside = Paper(title: "Private", kind: .notebook, pages: [SheetPage(typed: "Private notes")])
        XCTAssertTrue(studio.change { $0.addProject(project); $0.papers.append(outside) })
        let agent = AgentTools(studio: studio, access: .project(project.id))
        let id = UUID()
        let canvas = try tool(agent, "create_canvas", ["id": id.uuidString, "title": "Agent canvas"])
        XCTAssertFalse(canvas.error)
        let item = try XCTUnwrap(studio.paper(id))
        let page = item.pages[0].id.uuidString
        XCTAssertTrue(try tool(agent, "read_markdown", ["id": outside.id.uuidString]).error)
        XCTAssertFalse(try tool(agent, "list_library", [:]).text.contains("Private"))
        let nodes: [[String: Any]] = [
            ["kind": "note", "title": "First", "x": -250, "y": 0, "markdown": "**Check**"],
            ["kind": "diamond", "title": "Decision", "x": 200, "y": 0]
        ]
        var args: [String: Any] = ["page_id": page, "request_id": UUID().uuidString, "items": nodes, "connections": [["from": 0, "to": 9]]]
        XCTAssertTrue(try tool(agent, "add_canvas_items", args).error)
        XCTAssertNil(studio.paper(id)?.pages[0].canvas)
        args["connections"] = [["from": 0, "to": 1, "label": "Then"]]
        let added = try tool(agent, "add_canvas_items", args)
        XCTAssertFalse(added.error)
        XCTAssertEqual(try tool(agent, "add_canvas_items", args).text, added.text)
        XCTAssertEqual(studio.paper(id)?.pages[0].canvas?.items.count, 2)
        XCTAssertEqual(studio.paper(id)?.pages[0].canvas?.connections.count, 1)
        XCTAssertTrue(try tool(agent, "read_markdown", ["id": id.uuidString]).text.contains("**Check**"))
    }

    @MainActor func testAgentCanReadAndWriteOnlyExplicitlySelectedItems() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let studio = Studio(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = Paper(title: "Secret notebook", kind: .notebook, pages: [SheetPage(typed: "Private material")])
        let secretRef = LibraryReference(.paper, secret.id)
        let hiddenBlock = Block(title: "Hidden template", values: ["process": "Do not disclose this step"])
        let visibleBlock = Block(title: "Shared variation", parentID: hiddenBlock.id, values: ["outcome": "Shared result"])
        let workflow = Workflow(title: "My workflow", steps: [Placement(blockID: visibleBlock.id), Placement(blockID: hiddenBlock.id)])
        let note = CanvasItem(kind: .link, title: "Reference", link: secretRef.link, frame: CGRect(x: 0, y: 0, width: 250, height: 130))
        let board = Paper(title: "Choose me", kind: .whiteboard, pages: [SheetPage(canvas: CanvasContent(items: [note]))])
        let book = Paper(title: "Selected notes", kind: .notebook, pages: [SheetPage(typed: "First page"), SheetPage(typed: "Second page")])
        XCTAssertTrue(studio.change { $0.papers = [secret, board, book]; $0.blocks = [hiddenBlock, visibleBlock]; $0.workflows = [workflow] })
        let agent = AgentTools(studio: studio, access: .items([
            .init(.paper, board.id), .init(.paper, book.id), .init(.workflow, workflow.id), .init(.block, visibleBlock.id)
        ]))
        let advertised = String(decoding: agent.handle(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)), as: UTF8.self)
        XCTAssertFalse(advertised.contains("create_canvas"))
        let library = try tool(agent, "list_library", [:]).text
        XCTAssertTrue(library.contains("Choose me"))
        XCTAssertFalse(library.contains("Secret notebook"))
        XCTAssertTrue(try tool(agent, "read_markdown", ["id": secret.id.uuidString]).error)
        XCTAssertTrue(try tool(agent, "get_canvas", ["item_id": secret.id.uuidString]).error)
        XCTAssertTrue(try tool(agent, "get_canvas", ["item_id": book.id.uuidString]).error)
        XCTAssertTrue(try tool(agent, "get_canvas", ["item_id": board.id.uuidString, "page_id": book.pages[0].id.uuidString]).error)
        XCTAssertFalse(try tool(agent, "get_canvas", ["item_id": book.id.uuidString, "page_id": book.pages[0].id.uuidString]).error)
        let canvas = try tool(agent, "get_canvas", ["item_id": board.id.uuidString])
        XCTAssertFalse(canvas.error)
        XCTAssertFalse(canvas.text.contains(secret.id.uuidString))
        XCTAssertFalse(try tool(agent, "read_markdown", ["id": board.id.uuidString]).text.contains(secret.id.uuidString))
        let flow = try tool(agent, "read_markdown", ["id": workflow.id.uuidString]).text
        XCTAssertTrue(flow.contains("Shared result"))
        XCTAssertFalse(flow.contains("Hidden template"))
        XCTAssertFalse(flow.contains("Do not disclose"))
        XCTAssertTrue(try tool(agent, "create_canvas", ["id": UUID().uuidString, "title": "Out of scope"]).error)
        let items: [[String: Any]] = [["kind": "note", "title": "Allowed edit", "x": 85_000, "y": -9_000]]
        let request = UUID().uuidString
        XCTAssertTrue(try tool(agent, "add_canvas_items", ["item_id": secret.id.uuidString, "request_id": request, "items": items]).error)
        XCTAssertFalse(try tool(agent, "add_canvas_items", ["item_id": board.id.uuidString, "request_id": request, "items": items]).error)
        XCTAssertEqual(studio.paper(board.id)?.pages[0].canvas?.items.count, 2)
    }

    @MainActor func testAgentTransfersNotebookNotesAndOrganizesCanvasIntoProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let studio = Studio(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let agent = AgentTools(studio: studio, access: .library)
        let projectID = UUID()
        let notebookID = UUID()
        let boardID = UUID()
        let pageID = UUID()
        let project = ["id": projectID.uuidString, "title": "Transfer test"]
        let notebook = ["id": notebookID.uuidString, "title": "Teaching notebook", "markdown": "# Overview", "project_id": projectID.uuidString]
        XCTAssertFalse(try tool(agent, "create_project", project).error)
        XCTAssertFalse(try tool(agent, "create_notebook", notebook).error)
        XCTAssertFalse(try tool(agent, "create_notebook", notebook).error)
        XCTAssertFalse(try tool(agent, "create_canvas", ["id": boardID.uuidString, "title": "Teaching canvas"]).error)
        let membership = ["item_id": boardID.uuidString, "project_id": projectID.uuidString, "included": true] as [String: Any]
        XCTAssertFalse(try tool(agent, "set_project_membership", membership).error)
        XCTAssertTrue(try tool(agent, "list_projects", [:]).text.contains(boardID.uuidString))
        let page = ["item_id": notebookID.uuidString, "page_id": pageID.uuidString, "markdown": "Transferred notes"]
        XCTAssertFalse(try tool(agent, "add_notebook_page", page).error)
        XCTAssertFalse(try tool(agent, "add_notebook_page", page).error)
        XCTAssertEqual(studio.paper(notebookID)?.pages.count, 2)
        let notes = ["page_id": pageID.uuidString, "markdown": "Revised notes", "expected_markdown": "Transferred notes"]
        XCTAssertFalse(try tool(agent, "write_page_notes", notes).error)
        XCTAssertFalse(try tool(agent, "write_page_notes", notes).error)
        XCTAssertTrue(try tool(agent, "write_page_notes", notes.merging(["markdown": "Stale edit"]) { _, update in update }).error)
        XCTAssertTrue(try tool(agent, "read_markdown", ["id": notebookID.uuidString]).text.contains("Revised notes"))
        let add: [String: Any] = ["item_id": boardID.uuidString, "request_id": UUID().uuidString,
                                  "items": [["kind": "text", "title": "Draft", "x": 55, "y": 92, "glow": true]]]
        XCTAssertFalse(try tool(agent, "add_canvas_items", add).error)
        let object = try XCTUnwrap(studio.paper(boardID)?.pages.first?.canvas?.items.first)
        XCTAssertEqual(object.kind, .text)
        XCTAssertEqual(object.glow, true)
        let edit: [String: Any] = ["item_id": boardID.uuidString, "object_id": object.id.uuidString, "x": -750, "title": "Moved"]
        let scoped = AgentTools(studio: studio, access: .items([.init(.paper, notebookID)]))
        XCTAssertTrue(try tool(scoped, "update_canvas_item", edit).error)
        XCTAssertTrue(try tool(scoped, "set_project_membership", membership).error)
        XCTAssertFalse(try tool(agent, "update_canvas_item", edit).error)
        XCTAssertEqual(studio.paper(boardID)?.pages.first?.canvas?.items.first?.frame.minX, -750)
        XCTAssertTrue(try tool(agent, "read_markdown", ["id": boardID.uuidString]).text.contains("Moved"))
    }

    @MainActor func testEncryptedMCPListenerAcceptsAuthorizedClient() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = Studio(folder: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AgentSession()
        defer { session.stop() }
        session.start(studio: store, access: .library, host: "127.0.0.1")
        for _ in 0..<40 where session.pairing == nil { try await Task.sleep(for: .milliseconds(50)) }
        let pairing = try XCTUnwrap(session.pairing, session.failure ?? "No listener")
        let key = try SymmetricKey(data: XCTUnwrap(Data(base64Encoded: pairing.key)))
        let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let packet = try AgentWire.request(message, key: key)
        XCTAssertThrowsError(try AgentWire.openRequest(packet, key: SymmetricKey(size: .bits256)))
        XCTAssertThrowsError(try AgentWire.openRequest(packet, key: key, now: .now.addingTimeInterval(100)))
        let client = NWConnection(host: "127.0.0.1", port: pairing.port, using: .tcp)
        defer { client.cancel() }
        let wire = try AgentWire.frame(packet)
        let replied = expectation(description: "Encrypted MCP reply")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: wire, completion: .contentProcessed { problem in
                XCTAssertNil(problem)
                AgentWire.receive(client) { received in
                    do {
                        let encrypted = try received.get()
                        let plain = try AgentWire.openReply(encrypted, for: packet, key: key)
                        XCTAssertTrue(String(decoding: plain, as: UTF8.self).contains("add_canvas_items"))
                        XCTAssertThrowsError(try AgentWire.openReply(encrypted, for: Data(repeating: 0, count: 12), key: key))
                    } catch { XCTFail(error.localizedDescription) }
                    replied.fulfill()
                }
            })
        }
        client.start(queue: .global())
        await fulfillment(of: [replied], timeout: 5)
    }

    @MainActor private func tool(_ agent: AgentTools, _ name: String, _ args: [String: Any]) throws -> (text: String, error: Bool) {
        let request = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]] as [String: Any]
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: agent.handle(JSONSerialization.data(withJSONObject: request))) as? [String: Any])
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (try XCTUnwrap(content.first?["text"] as? String), result["isError"] as? Bool ?? true)
    }
}
