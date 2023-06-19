
namespace Station.Simulation
{
    using Azure.Storage.Blobs;
    using Azure.Storage.Blobs.Models;
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Threading;
    using System.Threading.Tasks;

    public class AzureFileStorage
    {
        private string _blobContainerName = "uacloudpublisher";

        public AzureFileStorage()
        {
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STORAGE_CONTAINER_NAME")))
            {
                _blobContainerName = Environment.GetEnvironmentVariable("STORAGE_CONTAINER_NAME");
            }
        }

        public async Task<string> FindFileAsync(string path, string name, CancellationToken cancellationToken = default)
        {
            try
            {
                if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING")))
                {
                    // open blob storage
                    BlobContainerClient container = new BlobContainerClient(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING"), _blobContainerName);
                    await container.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

                    var resultSegment = container.GetBlobsAsync();
                    await foreach (BlobItem blobItem in resultSegment.ConfigureAwait(false))
                    {
                        if (blobItem.Name.Contains(path.TrimStart('/')) && blobItem.Name.Contains(name))
                        {
                            return blobItem.Name;
                        }
                    }
                }

                return null;
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
                return null;
            }
        }

        public async Task<string[]> FindFilesAsync(string path, CancellationToken cancellationToken = default)
        {
            try
            {
                List<string> files = new List<string>();

                if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING")))
                {
                    // open blob storage
                    BlobContainerClient container = new BlobContainerClient(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING"), _blobContainerName);
                    await container.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

                    var resultSegment = container.GetBlobsAsync();
                    await foreach (BlobItem blobItem in resultSegment.ConfigureAwait(false))
                    {
                        files.Add(blobItem.Name);
                    }

                    return files.ToArray();
                }
                else
                {
                    return null;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
                return null;
            }
        }

        public async Task<string> StoreFileAsync(string path, byte[] content, CancellationToken cancellationToken = default)
        {
            if (string.IsNullOrEmpty(path) || (content == null))
            {
                return null;
            }

            try
            {
                if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING")))
                {
                    // open blob storage
                    BlobContainerClient container = new BlobContainerClient(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING"), _blobContainerName);
                    await container.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

                    // Get a reference to the blob
                    BlobClient blob = container.GetBlobClient(path);

                    // Open the file and upload its data
                    using (MemoryStream file = new MemoryStream(content))
                    {
                        await blob.DeleteIfExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                        await blob.UploadAsync(file, cancellationToken).ConfigureAwait(false);

                        // Verify uploaded
                        BlobProperties properties = await blob.GetPropertiesAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                        if (file.Length != properties.ContentLength)
                        {
                            throw new Exception("Could not verify upload!");
                        }

                        return path;
                    }
                }

                return null;
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
                return null;
            }
        }

        public async Task<byte[]> LoadFileAsync(string name, CancellationToken cancellationToken = default)
        {
            if (string.IsNullOrEmpty(name))
            {
                return null;
            }

            try
            {
                if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING")))
                {
                    // open blob storage
                    BlobContainerClient container = new BlobContainerClient(Environment.GetEnvironmentVariable("STORAGE_CONNECTION_STRING"), _blobContainerName);
                    await container.CreateIfNotExistsAsync(cancellationToken: cancellationToken).ConfigureAwait(false);

                    var resultSegment = container.GetBlobsAsync();
                    await foreach (BlobItem blobItem in resultSegment.ConfigureAwait(false))
                    {
                        if (blobItem.Name.Equals(name))
                        {
                            // Get a reference to the blob
                            BlobClient blob = container.GetBlobClient(blobItem.Name);

                            // Download the blob's contents and save it to a file
                            BlobDownloadInfo download = await blob.DownloadAsync(cancellationToken).ConfigureAwait(false);
                            using (MemoryStream file = new MemoryStream())
                            {
                                await download.Content.CopyToAsync(file, cancellationToken).ConfigureAwait(false);

                                // Verify download
                                BlobProperties properties = await blob.GetPropertiesAsync(cancellationToken: cancellationToken).ConfigureAwait(false);
                                if (file.Length != properties.ContentLength)
                                {
                                    throw new Exception("Could not verify upload!");
                                }

                                return file.ToArray();
                            }
                        }
                    }
                }

                return null;
            }
            catch (Exception ex)
            {
                Console.WriteLine("Error: " + ex.Message);
                return null;
            }
        }
    }
}
