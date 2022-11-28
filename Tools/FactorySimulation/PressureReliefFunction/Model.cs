
namespace PressureRelief
{
    using System;

    class RequestModel
    {
        public Guid CorrelationId { get; set; }

        public DateTime TimeStamp { get; set; }

        public string Endpoint { get; set; }

        public string MethodNodeId { get; set; }

        public string ParentNodeId { get; set; }

        public string[] Arguments { get; set; }
    }

    class ResponseModel
    {
        public Guid CorrelationId { get; set; }

        public DateTime TimeStamp { get; set; }

        public bool Success { get; set; }

        public string Status { get; set; }
    }
}
