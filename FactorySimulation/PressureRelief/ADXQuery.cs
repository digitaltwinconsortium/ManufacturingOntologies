
namespace PressureRelief
{
    using Microsoft.Azure.WebJobs;
    using Microsoft.Extensions.Logging;
    using System;

    public class ADXQuery
    {
        [FunctionName("ADXQuery")]
        public void Run([TimerTrigger("*/15 * * * * *")]TimerInfo myTimer, ILogger log)
        {
            log.LogInformation($"C# Timer trigger function executed at: {DateTime.Now}");
        }
    }
}
