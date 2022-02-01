
namespace PressureRelief
{
    using System.Collections.Generic;

    public class MethodCallPayload
    {
        public UAServerEndpoint Endpoint { get; set; }

        public MethodCallRequest Request { get; set; }

        public MethodCallPayload()
        {
            Endpoint = new UAServerEndpoint();
            Request = new MethodCallRequest();
        }
    }

    public class UAServerEndpoint
    {
        public string Url { get; set; }

        public UAServerEndpoint()
        {
            Url = string.Empty;
        }
    }

    public class MethodCallRequest {

        public string MethodId { get; set; }

        /// <summary>
        /// Context of the method, i.e. an object or object type
        /// node. If null then the method is called in the context
        /// of the inverse HasComponent reference of the MethodId
        /// if it exists.
        /// </summary>
        public string ObjectId { get; set; }

        public List<MethodCallArgument> Arguments { get; set; }
    }

    public class MethodCallArgument
    {
        public string Value { get; set; }

        public string DataType { get; set; }
    }
}
