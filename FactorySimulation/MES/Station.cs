
namespace Mes.Simulation
{
    using Opc.Ua;
    using System.Runtime.Serialization;

    [DataContract(Name = "StationConfig", Namespace = Namespaces.OpcUaConfig)]
    public class Station
    {
        [DataMember(Order = 1, IsRequired = true)]
        public NodeId StatusNode { get; set; }

        [DataMember(Order = 2, IsRequired = true)]
        public NodeId RootMethodNode { get; set; }

        [DataMember(Order = 3, IsRequired = true)]
        public NodeId ResetMethodNode { get; set; }

        [DataMember(Order = 4, IsRequired = true)]
        public NodeId ExecuteMethodNode { get; set; }

        public Station() { }
    }
}
