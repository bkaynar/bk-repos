// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BKRepos",
    platforms: [.macOS(.v14)],
    targets: [
        // Depo keşfi, git çıktısı ayrıştırma, risk sınıflandırması ve korumalı işlemler.
        .target(name: "BKReposCore"),
        // Menü çubuğu uygulaması.
        .executableTarget(name: "BKRepos", dependencies: ["BKReposCore"]),
        // Aynı bulguları terminalde listeleyen, hiçbir şeyi değiştirmeyen komut satırı aracı.
        .executableTarget(name: "bkrepos-durum", dependencies: ["BKReposCore"]),
        .testTarget(name: "BKReposCoreTests", dependencies: ["BKReposCore"]),
    ],
    swiftLanguageModes: [.v5]
)
