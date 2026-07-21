# Multi-stage build for the Plant Copilot MCP server.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY PlantCopilot.csproj ./
RUN dotnet restore PlantCopilot.csproj

COPY . ./
RUN dotnet publish PlantCopilot.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
WORKDIR /app
COPY --from=build /app ./

# The MCP server listens on port 8080 (Streamable HTTP transport at /mcp).
EXPOSE 8080
ENV ASPNETCORE_HTTP_PORTS=8080

ENTRYPOINT ["dotnet", "PlantCopilot.dll"]
