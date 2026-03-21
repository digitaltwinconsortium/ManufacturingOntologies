/* ========================================================================
 * Copyright (c) 2005-2025 The OPC Foundation, Inc. All rights reserved.
 *
 * OPC Foundation MIT License 1.00
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use,
 * copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 * OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 * The complete license agreement can be found here:
 * http://opcfoundation.org/License/MIT/1.00/
 * ======================================================================*/

using Microsoft.Extensions.Logging;
using Serilog;
using Serilog.Events;
using System;
using System.Diagnostics;
using System.Diagnostics.Metrics;
using System.IO;
using System.Threading.Tasks;

namespace Opc.Ua.Cloud
{
    public class ConsoleTelemetry : ITelemetryContext, IDisposable
    {
        public ConsoleTelemetry(Action<ILoggingBuilder> configure = null)
        {
            string logDirectory = Path.Combine(Directory.GetCurrentDirectory(), "logs");
            if (!Directory.Exists(logDirectory))
            {
                Directory.CreateDirectory(logDirectory);
            }

            Log.Logger = new LoggerConfiguration()
                .MinimumLevel.Information()
                .MinimumLevel.Override("Microsoft", LogEventLevel.Warning)
                .Enrich.FromLogContext()
                .WriteTo.Console(
                    outputTemplate: "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}")
                .WriteTo.File(
                    path: "logs/station-.log",
                    rollingInterval: RollingInterval.Day,
                    retainedFileCountLimit: 7,
                    outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
                .CreateLogger();

            LoggerFactory = Microsoft.Extensions.Logging.LoggerFactory.Create(builder =>
            {
                builder.SetMinimumLevel(LogLevel.Information);
                configure?.Invoke(builder);
            }).AddSerilog(Log.Logger);

            AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;
            TaskScheduler.UnobservedTaskException += Unobserved_TaskException;
        }

        public ILoggerFactory LoggerFactory { get; internal set; }

        public Meter CreateMeter() => new("UA cloud app", "1.0.0");

        public ActivitySource ActivitySource { get; } = new("UA cloud app", "1.0.0");

        public void Dispose()
        {
            CreateMeter().Dispose();
            ActivitySource.Dispose();
            LoggerFactory?.Dispose();
            Log.CloseAndFlush();

            AppDomain.CurrentDomain.UnhandledException -= CurrentDomain_UnhandledException;
            TaskScheduler.UnobservedTaskException -= Unobserved_TaskException;
        }

        private void CurrentDomain_UnhandledException(
            object sender,
            UnhandledExceptionEventArgs args)
        {
            Log.Logger.Error(
                args.ExceptionObject as Exception,
                "Unhandled Exception: (IsTerminating: {IsTerminating})",
                args.IsTerminating);
        }

        private void Unobserved_TaskException(
            object sender,
            UnobservedTaskExceptionEventArgs args)
        {
            Log.Logger.Error(
                args.Exception,
                "Unobserved Task Exception (Observed: {Observed})",
                args.Observed);
        }
    }
}
