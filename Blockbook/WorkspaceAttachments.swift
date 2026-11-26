import Foundation
import CryptoKit

struct WorkspaceFile {
    let relative: String
    let bytes: Int
    let chunks: [String]
    var body: [String:Any] { ["path":relative,"bytes":bytes,"chunks":chunks] }
    static let size=256*1024
    static func sha(_ data:Data)->String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func sources(_ library:Library,project:Project,folder:URL) -> Set<String> {
        var paths=Set<String>()
        for ref in project.entries where ref.kind == .paper {
            guard let paper=library.papers.first(where:{$0.id==ref.id}) else {continue}
            if paper.kind == .pdf { paths.insert(paper.id.uuidString+".pdf") }
            for page in paper.pages {
                let ink=page.id.uuidString+".drawing"
                if FileManager.default.fileExists(atPath:folder.appendingPathComponent(ink).path) {paths.insert(ink)}
                for asset in page.canvas?.items.flatMap(\.ownedAssets) ?? [] { paths.insert("Assets/"+asset.storageName) }
                if let visual=page.visual { paths.insert("Assets/"+visual.filename) }
            }
        }
        return paths
    }
    static func safe(_ path:String)->Bool {
        let parts=path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count==1 || (parts.count==2 && parts.first=="Assets"),let last=parts.last else {return false}
        let name=String(last) as NSString,ext=name.pathExtension
        return UUID(uuidString:name.deletingPathExtension) != nil && ext.count <= 12 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    static func publish(_ path:String,folder:URL) async throws -> WorkspaceFile {
        guard safe(path) else {throw WorkspaceError.message("Invalid attachment path.")}
        let file=folder.appendingPathComponent(path),values=try file.resourceValues(forKeys:[.contentModificationDateKey,.fileSizeKey])
        let stamp="\(values.fileSize ?? -1)/\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let key=WorkspaceConnection.origin+".file."+folder.path+"."+path,defaults=UserDefaults.standard
        if let saved=defaults.dictionary(forKey:key), saved["stamp"] as? String==stamp,let chunks=saved["chunks"] as? [String],let bytes=values.fileSize { return .init(relative:path,bytes:bytes,chunks:chunks) }
        let input=try FileHandle(forReadingFrom:file);defer {try? input.close()}
        var hashes:[String]=[],bytes=0
        while let data=try input.read(upToCount:size),!data.isEmpty {hashes.append(sha(data));bytes+=data.count}
        let check=try await WorkspaceConnection.request("/v1/chunks",["check":hashes]) as? [String:Any]
        guard let missing=check?["missing"] as? [String] else {throw WorkspaceError.message("Could not verify attachment chunks.")}
        var need=Set(missing)
        for (index,hash) in hashes.enumerated() where need.remove(hash) != nil {
            try input.seek(toOffset:UInt64(index*size))
            guard let data=try input.read(upToCount:size),sha(data)==hash else {throw WorkspaceError.message("Attachment changed during sync.")}
            _=try await WorkspaceConnection.request("/v1/chunks",["hash":hash,"data":data.base64EncodedString()])
        }
        defaults.set(["stamp":stamp,"chunks":hashes],forKey:key)
        return .init(relative:path,bytes:bytes,chunks:hashes)
    }
    static func restore(_ row:[String:Any],project:UUID,into staging:URL) async throws {
        guard let record=row["id"] as? String,let body=row["body"] as? [String:Any],let path=body["path"] as? String,safe(path),let chunks=body["chunks"] as? [String],let length=body["bytes"] as? Int,length>=0,chunks.count==(length+size-1)/size else {throw WorkspaceError.message("Invalid attachment manifest.")}
        let file=staging.appendingPathComponent(path)
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard FileManager.default.createFile(atPath:file.path,contents:nil) else {throw WorkspaceError.message("Could not stage a downloaded attachment.")}
        let output=try FileHandle(forWritingTo:file);defer {try? output.close()}
        for (i,hash) in chunks.enumerated() {
            let chunk=try await WorkspaceConnection.action("read_asset",project:project,args:["record":record,"index":i])
            guard let encoded=chunk["data"] as? String, let data=Data(base64Encoded:encoded),data.count<=size,sha(data)==hash else {throw WorkspaceError.message("Attachment checksum mismatch.")}
            try output.write(contentsOf:data)
        }
        guard try output.offset()==length else {throw WorkspaceError.message("Incomplete attachment.")}
    }
}
