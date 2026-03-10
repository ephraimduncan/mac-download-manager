import Testing

@testable import Mac_Download_Manager

@Suite
struct Aria2ClientTests {
  @Test func clientInitializes() {
    let client = Aria2Client(port: 6800, secret: "test-secret")
    _ = client
  }
}
