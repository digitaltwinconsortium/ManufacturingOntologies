
namespace Station.Simulation
{
    using Opc.Ua;
    using Opc.Ua.Server;
    using System;
    using System.Collections.Generic;


    public class MESNodeManager : CustomNodeManager2
    {
        private ushort m_namespaceIndex = 0;
        private long m_lastUsedId = 0;

        public MESNodeManager(IServerInternal server, ApplicationConfiguration configuration)
        : base(server, configuration)
        {
            List<string> namespaceUris = new()
            {
                "http://opcfoundation.org/UA/Station-MES/"
            };

            NamespaceUris = namespaceUris;

            m_namespaceIndex = Server.NamespaceUris.GetIndexOrAppend(namespaceUris[0]);

            SystemContext.NodeIdFactory = this;
        }

        public override NodeId New(ISystemContext context, NodeState node)
        {
            return new NodeId(Utils.IncrementIdentifier(ref m_lastUsedId), m_namespaceIndex);
        }

        public override void CreateAddressSpace(IDictionary<NodeId, IList<IReference>> externalReferences)
        {
            lock (Lock)
            {
                IList<IReference> objectsFolderReferences = null;
                if (!externalReferences.TryGetValue(ObjectIds.ObjectsFolder, out objectsFolderReferences))
                {
                    externalReferences[ObjectIds.ObjectsFolder] = objectsFolderReferences = new List<IReference>();
                }

                if (Program.ShiftTimes.Count > 2)
                {
                    BaseObjectState root = CreateRootNode(objectsFolderReferences, "Shift Times");
                    CreateVariable(root, Program.ShiftTimes[0].Item1, new ExpandedNodeId(DataTypes.String), m_namespaceIndex, Program.ShiftTimes[0].Item2 + "," + Program.ShiftTimes[0].Item3);
                    CreateVariable(root, Program.ShiftTimes[1].Item1, new ExpandedNodeId(DataTypes.String), m_namespaceIndex, Program.ShiftTimes[1].Item2 + "," + Program.ShiftTimes[1].Item3);
                    CreateVariable(root, Program.ShiftTimes[2].Item1, new ExpandedNodeId(DataTypes.String), m_namespaceIndex, Program.ShiftTimes[2].Item2 + "," + Program.ShiftTimes[2].Item3);
                }

                AddReverseReferences(externalReferences);
                base.CreateAddressSpace(externalReferences);
            }
        }

        private BaseObjectState CreateRootNode(IList<IReference> objectsFolderReferences, string name)
        {
            FolderState node = new FolderState(null)
            {
                NodeId = new NodeId(name, NamespaceIndex),
                BrowseName = new QualifiedName(name, NamespaceIndex),
                DisplayName = new LocalizedText("en", name),
                TypeDefinitionId = ObjectTypeIds.FolderType
            };

            node.AddReference(ReferenceTypeIds.Organizes, true, ObjectIds.ObjectsFolder);
            objectsFolderReferences.Add(new NodeStateReference(ReferenceTypeIds.Organizes, false, node.NodeId));
            AddPredefinedNode(SystemContext, node);

            return node;
        }

        private void CreateVariable(NodeState parent, string name, ExpandedNodeId type, ushort namespaceIndex, object value)
        {
            BaseDataVariableState variable = new BaseDataVariableState(parent)
            {
                SymbolicName = name,
                ReferenceTypeId = ReferenceTypes.Organizes,
                NodeId = new NodeId(name, namespaceIndex),
                BrowseName = new QualifiedName(name, namespaceIndex),
                DisplayName = new LocalizedText("en", name),
                WriteMask = AttributeWriteMask.None,
                UserWriteMask = AttributeWriteMask.None,
                AccessLevel = AccessLevels.CurrentRead,
                DataType = ExpandedNodeId.ToNodeId(type, Server.NamespaceUris),
                Value = value,
                Timestamp = DateTime.UtcNow
            };

            parent?.AddChild(variable);
            AddPredefinedNode(SystemContext, variable);
        }
    }
}
