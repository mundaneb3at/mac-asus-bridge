using System;
using System.IO;

public static class ClaudeStub
{
    public static int Main(string[] args)
    {
        File.WriteAllLines(Environment.GetEnvironmentVariable("FAKE_ARGS_CAPTURE"), args);
        using (var input = Console.OpenStandardInput())
        using (var saved = File.Create(Environment.GetEnvironmentVariable("FAKE_CLAUDE_INPUT")))
        {
            input.CopyTo(saved);
        }
        for (var i = 0; i + 1 < args.Length; i++)
        {
            if (args[i] == "--settings")
                File.Copy(args[i + 1], Environment.GetEnvironmentVariable("FAKE_SETTINGS_CAPTURE"), true);
        }
        if (Environment.GetEnvironmentVariable("FAKE_MODE") == "claude_error")
        {
            Console.Error.Write("stub failure sk-ant-oat01-EXAMPLE");
            return 9;
        }
        Console.Write(Environment.GetEnvironmentVariable("FAKE_ANSWER") ?? "ASUS answer");
        return 0;
    }
}
