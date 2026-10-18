// =====================================================================
//  SourceFiles         (staging query  ->  right-click > UNTICK "Enable load")
//
//  Lists every .json file in the landing folder. The pipeline writes three
//  kinds of file there and each has its own query:
//     genesys-audit_YYYY-MM-DD.json      -> AuditEventsRaw
//     genesys-apiusage_YYYY-MM-DD.json   -> ApiUsage
//     genesys-oauthclients.json          -> OAuthClients
//  The connector (local folder or SharePoint) is chosen here only.
// =====================================================================
let
    // Exactly ONE of the two blocks below must be active. tools/build_pbip.py
    // flips them to produce the "local" and "sharepoint" template variants;
    // by hand: comment one block out and uncomment the other.
    //
    // >>> SOURCE:LOCAL   (Desktop development: a local or network folder)
    Files = Folder.Files(AuditSourcePath),
    // <<< SOURCE:LOCAL
    //
    // >>> SOURCE:SHAREPOINT   (production: a SharePoint document library folder)
    // // SharePoint.Contents navigates the library segment by segment, e.g.
    // // SharePointFolder = "Shared Documents/GenesysAudit". Files must sit directly
    // // in that folder (no year/month sub-folders).
    // Site  = SharePoint.Contents(SharePointSiteUrl, [ApiVersion = 15]),
    // Files = List.Accumulate(
    //             List.Select(Text.Split(SharePointFolder, "/"), each _ <> ""),
    //             Site,
    //             (folder, part) => folder{[Name = part]}[Content]),
    // <<< SOURCE:SHAREPOINT
    //
    // Azure alternatives (same column shape, swap into the active block):
    //   Files = AzureStorage.Blobs(AuditSourcePath)
    //   Files = AzureStorage.DataLake(AuditSourcePath)

    JsonFiles = Table.SelectRows(Files, each [Extension] <> null and Text.Lower([Extension]) = ".json"),
    Kept      = Table.SelectColumns(JsonFiles, {"Content", "Name", "Date modified"})
in
    Kept
