// Recording-ready demo — paginated product catalog against DummyJSON.
//
// Why DummyJSON instead of GitHub for a live demo:
//   • No auth, no rate limit — won't fail on camera.
//   • /products is offset-paginated (skip/limit) and returns thumbnails,
//     so SmartAPI's pagination + AsyncImage looks great on video.
//   • Fast, reliable, ~194 products to scroll through.
//
// HOW TO RUN (for a screen recording):
//   1. In Xcode: File → New → Project → iOS → App. Name it "SmartAPIDemo".
//      Interface: SwiftUI. Language: Swift. Minimum: iOS 17.
//   2. File → Add Package Dependencies… →
//      https://github.com/AbhishekSuryawanshi/SmartAPI.git → Up to Next Major 0.1.0
//      → add the "SmartAPI" library to the app target.
//   3. Delete the template ContentView.swift. Drop THIS file into the project.
//   4. Open the app's `App` file and set the root view to `ProductsDemoApp()`:
//
//          @main struct SmartAPIDemoApp: App {
//              var body: some Scene { WindowGroup { ProductsDemoApp() } }
//          }
//
//   5. ⌘R. The first build is slow (compiles swift-syntax once). After that, instant.

import SwiftUI
import SmartAPI

// MARK: - Model (generated from a real DummyJSON response)

@SmartAPI(
    sample: """
    {
      "products": [
        {
          "id": 1,
          "title": "Essence Mascara Lash Princess",
          "description": "A popular mascara known for its volumizing effect.",
          "price": 9.99,
          "rating": 4.94,
          "brand": "Essence",
          "category": "beauty",
          "thumbnail": "https://cdn.dummyjson.com/products/images/beauty/thumbnail.png"
        }
      ],
      "total": 194,
      "skip": 0,
      "limit": 20
    }
    """,
    scope: .parseOnly,
    strict: false,
    paginated: .offset(
        items: "products",
        total: "total",
        offsetParam: "skip",
        limitParam: "limit",
        pageSize: 20
    )
)
enum Products {}

// MARK: - Client

enum Catalog {
    static let client = SmartClient(
        baseURL: URL(string: "https://dummyjson.com")!,
        retryPolicy: .standard,
        observer: SmartAPILogger.shared,   // watch the os.Logger output in Xcode console
        coalescer: RequestCoalescer()
    )

    static let productsURL = URL(string: "https://dummyjson.com/products")!
}

// MARK: - Root

struct ProductsDemoApp: View {
    var body: some View {
        NavigationStack {
            ProductListScreen()
                .navigationTitle("Products")
        }
    }
}

// MARK: - Paginated list (the star of the demo)

struct ProductListScreen: View {
    // One line: infinite scroll + pull-to-refresh + loading spinner, all handled.
    @State private var loader = Products.loader(
        url: Catalog.productsURL,
        fetcher: Catalog.client
    )

    var body: some View {
        SmartPaginatedView(loader: loader) { product in
            NavigationLink {
                ProductDetailScreen(product: product)
            } label: {
                ProductRow(product: product)
            }
        }
    }
}

// MARK: - Row + detail (your design system — generated UI is optional)

private struct ProductRow: View {
    let product: Products.Model

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: product.thumbnail) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.gray.opacity(0.15)
            }
            .frame(width: 56, height: 56)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(product.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(product.category.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("$\(product.price, specifier: "%.2f")")
                    .font(.subheadline.weight(.semibold))
                Label(String(format: "%.1f", product.rating), systemImage: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProductDetailScreen: View {
    let product: Products.Model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AsyncImage(url: product.thumbnail) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.gray.opacity(0.15)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(product.title)
                    .font(.title2.bold())

                HStack {
                    Text("$\(product.price, specifier: "%.2f")")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Label(String(format: "%.2f", product.rating), systemImage: "star.fill")
                        .foregroundStyle(.orange)
                }

                Text(product.brand)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(product.description)
                    .font(.body)
            }
            .padding()
        }
        .navigationTitle(product.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Preview

#Preview {
    ProductsDemoApp()
}
