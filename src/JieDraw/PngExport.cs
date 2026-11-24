using System;
using System.IO;

namespace JieDraw;

internal static class PngExport
{
    internal static string Save(string directory, string prefix, Action<Stream> encode)
    {
        if (string.IsNullOrWhiteSpace(directory))
            directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "JieDraw");
        Directory.CreateDirectory(directory);
        var stem = Path.Combine(directory, $"{prefix}_{DateTime.Now:yyyyMMdd_HHmmss}");
        var temp = Path.Combine(directory, Path.GetRandomFileName());
        using var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        try
        {
            encode(output);
            output.Close();
            for (int i = 0; ; i++)
            {
                var path = i == 0 ? stem + ".png" : $"{stem}_{i}.png";
                try
                {
                    File.Move(temp, path);
                    return path;
                }
                catch (IOException) when (File.Exists(path)) { }
            }
        }
        finally
        {
            output.Close();
            File.Delete(temp);
        }
    }
}
