# __ProjectName__

__Description__

## Requirements

- .NET 10.0 or later

## Installation

Available on [NuGet.org](https://www.nuget.org/packages/__ProjectName__).

```sh
dotnet add package __ProjectName__
```

## Usage

```csharp
using __ProjectName__;

var greeting = Greeter.Greet("World"); // "Hello, World!"
```

TODO: replace the placeholder API above and document the real public surface.

## Verifying the package

> Applies when the project ships a NuGet package. Remove this section for apps
> or internal libraries.

Each GitHub Release ships a `SHA256SUMS` file alongside the `.nupkg` / `.snupkg`.
Download all three into the same directory, then:

```sh
sha256sum -c SHA256SUMS
```

Expected:

```
__ProjectName__.<version>.nupkg: OK
__ProjectName__.<version>.snupkg: OK
```

The package on NuGet.org carries a repository signature from nuget.org. You can
inspect it with `dotnet nuget verify __ProjectName__.<version>.nupkg --all`.

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for the version history.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for build/test instructions and
conventions. Windows developers can also run the suite in a Linux container;
see [docs/linux-testing.md](docs/linux-testing.md) for the safe filtering and
rebuild options. To report a security issue, follow [SECURITY.md](SECURITY.md)
— please do not open a public issue.

## License

This project is licensed under the [MIT License](LICENSE).
