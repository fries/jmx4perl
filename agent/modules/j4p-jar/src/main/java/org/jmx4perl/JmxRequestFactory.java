package org.jmx4perl;

import org.jmx4perl.JmxRequest.Type;
import org.json.simple.parser.JSONParser;
import org.json.simple.parser.ParseException;

import javax.management.MalformedObjectNameException;
import javax.servlet.ServletInputStream;
import java.io.UnsupportedEncodingException;
import java.io.Reader;
import java.io.IOException;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Factory for creating {@link org.jmx4perl.JmxRequest}s
 *
 * @author roland
 * @since Oct 29, 2009
 */
class JmxRequestFactory {

    // Pattern for detecting escaped slashes in URL encoded requests
    private static final Pattern SLASH_ESCAPE_PATTERN = Pattern.compile("^-*\\+?$");

    // private constructor for static class
    private JmxRequestFactory() { }

    /**
     *
     * Create a JMX request from a GET Request with a REST Url.
     * <p>
     * The REST-Url which gets recognized has the following format:
     * <p>
     * <pre>
     *    &lt;base_url&gt;/&lt;type&gt;/&lt;param1&gt;/&lt;param2&gt;/....
     * </pre>
     * <p>
     * where <code>base_url<code> is the URL specifying the overall servlet (including
     * the servlet context, something like "http://localhost:8080/j4p-agent"),
     * <code>type</code> the operational mode and <code>param1 .. paramN<code>
     * the provided parameters which are dependend on the <code>type<code>
     * <p>
     * The following types are recognized so far, along with there parameters:
     *
     * <ul>
     *   <li>Type: <b>read</b> ({@link Type#READ}<br/>
     *       Parameters: <code>param1<code> = MBean name, <code>param2</code> = Attribute name,
     *       <code>param3 ... paramN</code> = Inner Path.
     *       The inner path is optional and specifies a path into complex MBean attributes
     *       like collections or maps. If within collections/arrays/tabular data,
     *       <code>paramX</code> should specify
     *       a numeric index, in maps/composite data <code>paramX</code> is a used as a string
     *       key.</li>
     *   <li>Type: <b>write</b> ({@link Type#WRITE}<br/>
     *       Parameters: <code>param1</code> = MBean name, <code>param2</code> = Attribute name,
     *       <code>param3</code> = value, <code>param4 ... paramN</code> = Inner Path.
     *       The value must be URL encoded (with UTF-8 as charset), and must be convertable into
     *       a data structure</li>
     *   <li>Type: <b>exec</b> ({@link Type#EXEC}<br/>
     *       Parameters: <code>param1</code> = MBean name, <code>param2</code> = operation name,
     *       <code>param4 ... paramN</code> = arguments for the operation.
     *       The arguments must be URL encoded (with UTF-8 as charset), and must be convertable into
     *       a data structure</li>
     *    <li>Type: <b>version</b> ({@link Type#VERSION}<br/>
     *        Parameters: none
     *    <li>Type: <b>search</b> ({@link Type#SEARCH}<br/>
     *        Parameters: <code>param1</code> = MBean name pattern
     * </ul>
     * @param pPathInfo path info of HTTP request
     * @param pParameterMap HTTP Query parameters
     * @return a newly created {@link org.jmx4perl.JmxRequest}
     */
    static JmxRequest createRequestFromUrl(String pPathInfo, Map pParameterMap) {
        JmxRequest request = null;
        try {
            if (pPathInfo != null && pPathInfo.length() > 0) {

                // Get all path elements as a reverse stack
                Stack<String> elements = extractElementsFromPath(pPathInfo);
                Type type = extractType(elements.pop());

                Processor processor = processorMap.get(type);
                if (processor == null) {
                    throw new UnsupportedOperationException("Type " + type + " is not supported (yet)");
                }

                // Parse request
                request = processor.process(elements);

                // Extract all additional args from the remaining path info
                request.setExtraArgs(toList(elements));

                // Setup JSON representation
                extractParameters(request,pParameterMap);
            }
            return request;
        } catch (NoSuchElementException exp) {
            throw new IllegalArgumentException("Invalid path info " + pPathInfo,exp);
        } catch (MalformedObjectNameException e) {
            throw new IllegalArgumentException("Invalid object name \"" + (request != null ? request.getObjectNameAsString() : "") + "\": " + e.getMessage(),e);
        } catch (UnsupportedEncodingException e) {
            throw new IllegalStateException("Internal: Illegal encoding for URL conversion: " + e,e);
        } catch (EmptyStackException exp) {
            throw new IllegalArgumentException("Invalid arguments in pathinfo " + pPathInfo + (request != null ? " for command " + request.getType() : ""),exp);
        }
    }


    /**
     * Create a list of {@link JmxRequest}s from the (POST) JSON content of an agent.
     *
     * @param content JSON representation of a {@link org.jmx4perl.JmxRequest}
     * @return list with one or more requests
     */
    static List<JmxRequest> createRequestsFromInputStream(Reader content) throws MalformedObjectNameException, IOException {
        try {
            JSONParser parser = new JSONParser();
            Object json = parser.parse(content);
            List<JmxRequest> ret = new ArrayList<JmxRequest>();
            if (json instanceof List) {
                for (Object o : (List) json) {
                    if (!(o instanceof Map)) {
                        throw new IllegalArgumentException("Not a request within the list for the " + content + ". Expected map, but found: " + o);
                    }
                    ret.add(new JmxRequest((Map) o));
                }
            } else if (json instanceof Map) {
                ret.add(new JmxRequest((Map) json));
            } else {
                throw new IllegalArgumentException("Invalid JSON Request " + content);
            }
            return ret;
        } catch (ParseException e) {
            throw new IllegalArgumentException("Invalid JSON request " + content,e);
        }
    }

    /*
    We need to use this special treating for slashes (i.e. to escape with '/-/') because URI encoding doesnt work
    well with HttpRequest.pathInfo() since in Tomcat/JBoss slash seems to be decoded to early so that it get messed up
    and answers with a "HTTP/1.x 400 Invalid URI: noSlash" without returning any further indications

    For the rest of unsafe chars, we use uri decoding (as anybody should do). It could be of course the case,
    that the pathinfo has been already uri decoded (dont know by heart)
     */
    static private Stack<String> extractElementsFromPath(String path) throws UnsupportedEncodingException {
        String[] elements = (path.startsWith("/") ? path.substring(1) : path).split("/+");

        Stack<String> ret = new Stack<String>();
        Stack<String> elementStack = new Stack<String>();

        for (int i=elements.length-1;i>=0;i--) {
            elementStack.push(elements[i]);
        }

        extractElements(ret,elementStack,null);
        if (ret.size() == 0) {
            throw new IllegalArgumentException("No request type given");
        }

        // Reverse stack
        Collections.reverse(ret);

        return ret;
    }


    static private void extractElements(Stack<String> ret, Stack<String> pElementStack,StringBuffer previousBuffer)
            throws UnsupportedEncodingException {
        if (pElementStack.isEmpty()) {
            if (previousBuffer != null && previousBuffer.length() > 0) {
                ret.push(decode(previousBuffer.toString()));
            }
            return;
        }
        String element = pElementStack.pop();
        Matcher matcher = SLASH_ESCAPE_PATTERN.matcher(element);
        if (matcher.matches()) {
            if (ret.isEmpty()) {
                return;
            }
            StringBuffer val;
            if (previousBuffer == null) {
                val = new StringBuffer(ret.pop());
            } else {
                val = previousBuffer;
            }
            // Decode to value
            for (int j=0;j<element.length();j++) {
                val.append("/");
            }
            // Special escape at the end indicates that this is the last element in the path
            if (!element.substring(element.length()-1,1).equals("+")) {
                if (!pElementStack.isEmpty()) {
                    val.append(decode(pElementStack.pop()));
                }
                extractElements(ret,pElementStack,val);
                return;
            } else {
                ret.push(decode(val.toString()));
                extractElements(ret,pElementStack,null);
                return;
            }
        }
        if (previousBuffer != null) {
            ret.push(decode(previousBuffer.toString()));
        }
        ret.push(decode(element));
        extractElements(ret,pElementStack,null);
    }

    private static String decode(String s) {
        return s;
        //return URLDecoder.decode(s,"UTF-8");

    }

    static private Type extractType(String pTypeS) {
        for (Type t : Type.values()) {
            if (t.getValue().equals(pTypeS)) {
                return t;
            }
        }
        throw new IllegalArgumentException("Invalid request type '" + pTypeS + "'");
    }

    private static List<String>toList(Stack<String> pElements) {
        List<String> p = new ArrayList<String>();
        while (!pElements.isEmpty()) {
            p.add(pElements.pop());
        }
        return p;
    }

    private static void extractParameters(JmxRequest pRequest,Map pParameterMap) {
        if (pParameterMap != null) {
            if (pParameterMap.get("maxDepth") != null) {
                pRequest.setMaxDepth(Integer.parseInt( ((String []) pParameterMap.get("maxDepth"))[0]));
            }
            if (pParameterMap.get("maxCollectionSize") != null) {
                pRequest.setMaxCollectionSize(Integer.parseInt(((String []) pParameterMap.get("maxCollectionSize"))[0]));
            }
            if (pParameterMap.get("maxObjects") != null) {
                pRequest.setMaxObjects(Integer.parseInt(((String []) pParameterMap.get("maxObjects"))[0]));
            }
        }
    }


    // ==================================================================================
    // Dedicated parser for the various operations. They are installed as static processors.

    private interface Processor {
        JmxRequest process(Stack<String> e)
                throws MalformedObjectNameException;
    }

    final private static Map<Type,Processor> processorMap;



    static {
        processorMap = new HashMap<Type, Processor>();
        processorMap.put(Type.READ,new Processor() {
            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                JmxRequest req = new JmxRequest(Type.READ,e.pop());
                req.setAttributeName(e.pop());
                return req;
            }
        });
        processorMap.put(Type.WRITE,new Processor() {

            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                JmxRequest req = new JmxRequest(Type.WRITE,e.pop());
                req.setAttributeName(e.pop());
                req.setValue(e.pop());
                return req;
            }
        });
        processorMap.put(Type.EXEC,new Processor() {
            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                JmxRequest req = new JmxRequest(Type.EXEC,e.pop());
                req.setOperation(e.pop());
                return req;
            }
        });

        processorMap.put(Type.LIST,new Processor() {
            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                return new JmxRequest(Type.LIST);
            }
        });
        processorMap.put(Type.VERSION,new Processor() {
            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                return new JmxRequest(Type.VERSION);
            }
        });

        processorMap.put(Type.SEARCH,new Processor() {
            public JmxRequest process(Stack<String> e) throws MalformedObjectNameException {
                return new JmxRequest(Type.SEARCH,e.pop());
            }
        });
    }

}