import XCTest
@testable import MediaSources

final class NetworkSourceParsingTests: XCTestCase {
    // MARK: FTP listings

    func testMLSDFactsBecomeEntries() {
        let text = """
        type=cdir;modify=20240101120000; .
        type=pdir; ..
        type=dir;modify=20240315083000;perm=el; Films
        type=file;size=734003200;modify=20240316101500; Galaxy Quest (1999).mkv
        """
        let entries = FTPListing.parseMLSD(text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0], FTPListing.Entry(name: "Films", isDirectory: true, size: nil, modified: FTPListing.date(fromMLSD: "20240315083000")))
        XCTAssertEqual(entries[1].name, "Galaxy Quest (1999).mkv")
        XCTAssertEqual(entries[1].size, 734_003_200)
        XCTAssertFalse(entries[1].isDirectory)
        XCTAssertEqual(entries[1].modified, FTPListing.date(fromMLSD: "20240316101500"))
    }

    func testUnixLISTLines() {
        let text = """
        total 12
        drwxr-xr-x   4 paul users     4096 Mar 15  2023 TV Shows
        -rw-r--r--   1 paul users 734003200 Jan 02 10:15 Galaxy Quest (1999).mkv
        lrwxrwxrwx   1 paul users       12 Jan 02 10:15 link -> target
        """
        let entries = FTPListing.parseLIST(text)
        XCTAssertEqual(entries.map(\.name), ["TV Shows", "Galaxy Quest (1999).mkv", "link"])
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertNil(entries[0].size)
        XCTAssertEqual(entries[1].size, 734_003_200)
        let year = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: entries[0].modified!).year
        XCTAssertEqual(year, 2023)
        XCTAssertNotNil(entries[1].modified, "a recent-file time with no year still yields a date")
    }

    func testWindowsLISTLines() {
        let entries = FTPListing.parseLIST("01-15-24  08:30PM       <DIR>          Films\r\n03-02-24  09:05AM           734003200 film.mkv\r\n")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].size, 734_003_200)
        let comps = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: entries[0].modified!)
        XCTAssertEqual([comps.year, comps.month, comps.day, comps.hour], [2024, 1, 15, 20])
    }

    func testMLSDDate() {
        let d = FTPListing.date(fromMLSD: "20240101120000.123")!
        XCTAssertEqual(d.timeIntervalSince1970, 1_704_110_400)
        XCTAssertNil(FTPListing.date(fromMLSD: "garbage"))
    }

    // MARK: UPnP

    func testSSDPLocation() {
        let response = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://192.168.1.5:8200/rootDesc.xml\r\nST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n"
        XCTAssertEqual(SSDP.location(in: response)?.absoluteString, "http://192.168.1.5:8200/rootDesc.xml")
        XCTAssertNil(SSDP.location(in: "HTTP/1.1 200 OK\r\n\r\n"))
    }

    func testDeviceDescriptionFindsContentDirectory() {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
            <friendlyName>Living room NAS</friendlyName>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
                <controlURL>/ctl/ConnectionMgr</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>
                <controlURL>/ctl/ContentDir</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
        let d = DeviceDescription.parse(Data(xml.utf8), base: URL(string: "http://192.168.1.5:8200/rootDesc.xml")!)
        XCTAssertEqual(d?.friendlyName, "Living room NAS")
        XCTAssertEqual(d?.controlURL.absoluteString, "http://192.168.1.5:8200/ctl/ContentDir")
        XCTAssertEqual(d?.serviceType, "urn:schemas-upnp-org:service:ContentDirectory:1")
    }

    func testDeviceDescriptionHonoursURLBase() {
        let xml = "<root><URLBase>http://10.0.0.2:9000/</URLBase><device><friendlyName>T</friendlyName><serviceList><service><serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType><controlURL>ctl/cds</controlURL></service></serviceList></device></root>"
        let d = DeviceDescription.parse(Data(xml.utf8), base: URL(string: "http://192.168.1.5:8200/x.xml")!)
        XCTAssertEqual(d?.controlURL.absoluteString, "http://10.0.0.2:9000/ctl/cds")
    }

    func testBrowseResponseAndDIDL() {
        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <container id="64" parentID="0" childCount="3"><dc:title>Films</dc:title><upnp:class>object.container.storageFolder</upnp:class></container>
          <item id="64$1" parentID="64"><dc:title>Galaxy Quest (1999)</dc:title><upnp:class>object.item.videoItem</upnp:class><dc:date>2024-03-16T10:15:00</dc:date>
            <res protocolInfo="http-get:*:image/jpeg:*" size="1000">http://192.168.1.5:8200/Thumbnails/1.jpg</res>
            <res protocolInfo="http-get:*:video/x-matroska:*" size="734003200" duration="1:42:00.000">http://192.168.1.5:8200/MediaItems/1.mkv</res>
          </item>
          <item id="64$2" parentID="64"><dc:title>cover</dc:title><upnp:class>object.item.imageItem.photo</upnp:class><res protocolInfo="http-get:*:image/jpeg:*">http://192.168.1.5:8200/MediaItems/2.jpg</res></item>
        </DIDL-Lite>
        """
        let envelope = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result>\(DIDL.escape(didl))</Result><NumberReturned>3</NumberReturned><TotalMatches>3</TotalMatches><UpdateID>5</UpdateID></u:BrowseResponse></s:Body></s:Envelope>
        """
        let result = DIDL.browseResult(Data(envelope.utf8))
        XCTAssertEqual(result.total, 3)
        let objects = DIDL.parse(result.didl)
        XCTAssertEqual(objects.count, 3)
        XCTAssertTrue(objects[0].isContainer)
        XCTAssertEqual(objects[0].fileName, "Films")
        let film = objects[1]
        XCTAssertFalse(film.isContainer)
        XCTAssertTrue(film.isVideo)
        XCTAssertEqual(film.resource?.absoluteString, "http://192.168.1.5:8200/MediaItems/1.mkv", "the video rendition wins over the thumbnail")
        XCTAssertEqual(film.size, 734_003_200)
        XCTAssertEqual(film.fileName, "Galaxy Quest (1999).mkv")
        XCTAssertEqual(film.fileName(suffix: " (2)"), "Galaxy Quest (1999) (2).mkv")
        XCTAssertNotNil(film.date)
        XCTAssertFalse(objects[2].isVideo, "a photo is not a library file")
    }

    func testFileNameKeepsAnExistingExtension() {
        let o = UPnPObject(id: "1", parentID: "0", title: "Episode 1.mkv", isContainer: false, upnpClass: "object.item.videoItem", resource: URL(string: "http://h/1.mkv"))
        XCTAssertEqual(o.fileName, "Episode 1.mkv")
        let slashes = UPnPObject(id: "2", parentID: "0", title: "A/B", isContainer: true)
        XCTAssertEqual(slashes.fileName, "A-B")
    }
}
