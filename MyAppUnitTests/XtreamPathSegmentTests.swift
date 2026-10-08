import Foundation
import Testing
@testable import BannerTV

/// Xtream stream URLs put the username and password in the path (`/live/{user}/{pass}/{id}.m3u8`), so a credential
/// containing `/ ? # %` or a space must be escaped to stay one segment.
@Suite("Xtream credentials in URLs")
struct XtreamPathSegmentTests {

    @Test("Ordinary credentials are left exactly as typed")
    func ordinary() {
        #expect("alice".xtreamPathSegment == "alice")
        #expect("pa55w0rd".xtreamPathSegment == "pa55w0rd")
        #expect("a.b-c_d~e".xtreamPathSegment == "a.b-c_d~e")
        #expect("user@mail.com".xtreamPathSegment == "user@mail.com")
        #expect("p@ss:w!rd$&'()*+,;=".xtreamPathSegment == "p@ss:w!rd$&'()*+,;=", "characters that are legal in a path segment stay")
    }

    @Test("Characters that would end or split a path segment are escaped")
    func escaped() {
        #expect("a/b".xtreamPathSegment == "a%2Fb")
        #expect("what?".xtreamPathSegment == "what%3F")
        #expect("pa#ss".xtreamPathSegment == "pa%23ss")
        #expect("100%".xtreamPathSegment == "100%25")
        #expect("two words".xtreamPathSegment == "two%20words")
    }

    @Test("A stream URL built from awkward credentials keeps its shape and decodes back")
    func roundTrip() throws {
        let accounts = [("alice", "s3cr3t"), ("u/ser", "p?a#s%s"), ("ünï", "pä ss/wörd"), ("a@b.c", "x:y")]
        for (user, pass) in accounts {
            let url = try #require(URL(string: "http://host.example:8080/live/\(user.xtreamPathSegment)/\(pass.xtreamPathSegment)/101.m3u8"))
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
                .split(separator: "/").map(String.init) ?? []
            #expect(parts.count == 4, "\(user) / \(pass): live, user, password, file")
            #expect(parts.first == "live")
            #expect(parts.last == "101.m3u8")
            #expect(parts.count == 4 && parts[1].removingPercentEncoding == user)
            #expect(parts.count == 4 && parts[2].removingPercentEncoding == pass)
            #expect(url.host == "host.example" && url.port == 8080, "the host isn't disturbed")
        }
    }
}
